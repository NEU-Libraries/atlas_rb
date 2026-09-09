# frozen_string_literal: true

module AtlasRb
  # HTTP transport helpers shared by every resource class.
  #
  # Every Atlas request reads these environment variables:
  #
  # - `ATLAS_URL`   — base URL of the Atlas API (e.g. `https://atlas.example.edu`).
  # - `ATLAS_JWT`   — *optional* personal-access JWT (minted by Atlas's
  #   `POST /nuid`, Cerberus-delegated post-SSO). When set, it switches the
  #   transport into **bring-your-own-JWT mode** (see below).
  #
  # ## Two transport modes
  #
  # **Relay-signing mode (default).** The regular relay path **signs** a
  # short-lived assertion (ES256, `iss=cerberus`, `aud=atlas`, `sub` = the
  # acting nuid) with Cerberus's private key — Atlas verifies it against the
  # matching public key. No `User:` header; identity is the proven `sub`.
  # **Acting-as rides a signed `obo` claim** inside the assertion (the target
  # can't be forged onto a stolen assertion; Atlas admin-gates the operator and
  # ignores any header obo on this path). When `nuid` / `on_behalf_of` are
  # omitted (positional arg `nil`, kwarg `nil`), the helper falls through to
  # {AtlasRb.config}'s `default_nuid` / `default_on_behalf_of` callables — host
  # applications wire those up to their request-scoped `Current.*` source;
  # caller-passed values always win. The key is configured via
  # {AtlasRb.config#assertion_signing_key} / `assertion_signing_kid`. This is
  # the path Cerberus uses.
  #
  # **BYO-JWT mode (`ATLAS_JWT` set).** Authenticates with the JWT, which
  # already encodes the acting user — so **no `User:` header is sent**, and
  # `On-Behalf-Of` is **suppressed** (Atlas rejects acting-as on the JWT path
  # with a 403; acting-as is a relay-only concept). `ATLAS_JWT` takes
  # precedence over relay-signing. This is the standalone-script path: a
  # librarian exports their minted token and runs headless against the API.
  #
  # If neither a signing key nor `ATLAS_JWT` is configured there is no relay
  # credential, so the transport raises {AtlasRb::ConfigurationError}.
  #
  # ## Instrumentation
  #
  # Every builder brackets its request in an `ActiveSupport::Notifications`
  # event named **`request.atlas_rb`** (Faraday's `:instrumentation`
  # middleware, wired above the whole stack so a redirect hop — e.g. the
  # `/resources/:noid` NOID resolver — folds into one event per logical call
  # rather than being double-counted; a retried call emits one event per
  # attempt). The payload is the Faraday `env`, so a
  # subscriber reads `payload.method` / `payload.url` and the event's duration.
  # This lets a host count/time Atlas round-trips (an N+1-over-HTTP detector)
  # without reaching into gem internals. It is guarded on
  # `defined?(ActiveSupport::Notifications)`: Rails hosts get the events; the
  # headless BYO-JWT path (no AS loaded) is unaffected. With no subscriber
  # attached the emit degrades to a listener lookup + `yield`, so it is safe to
  # leave in the stack permanently — opt-in lives entirely on the consumer side.
  #
  # ## Deadlines, retries, and read errors
  #
  # Three transport policies apply to the JSON and system connections:
  #
  # - **A deadline.** `open_timeout` and `timeout` are set from
  #   {AtlasRb::Transport}, because an unbounded read is not a problem the
  #   consumer can fix — a host can rescue what the gem raises, but it cannot
  #   impose a deadline on a socket the gem owns. See
  #   {AtlasRb::Configuration#read_timeout} for the numbers and the per-call
  #   override.
  # - **One retry layer.** An idempotent read that fails in transport is
  #   replayed with jittered backoff (see {#retry_reads}); `Net::HTTP`'s own
  #   silent replay is switched off in
  #   {AtlasRb::Transport.configure_persistent} so the two cannot multiply.
  # - **A read-error guard.** {Middleware::RaiseOnReadError} raises on a
  #   non-2xx read, so no binding can return an error body as if it were data.
  #
  # The multipart connection takes none of the three: a binary upload
  # legitimately runs for minutes, must not be replayed part-way through, and
  # is a write.
  #
  # ## Connection reuse
  #
  # The three builders do not return a `Faraday::Connection`. They return an
  # {AtlasRb::Transport::Proxy} over a shared, cached connection, so Atlas calls
  # reuse sockets instead of paying a TCP — and under TLS a full TLS —
  # handshake each time. The proxy answers the same verbs and forwards a block,
  # so call sites are unchanged. See {AtlasRb::Transport} for why the
  # connection has to be cached for keep-alive to happen at all, and
  # {AtlasRb::Transport.reset_connections!} for the test-suite teardown hook.
  #
  # The module is mixed in via `extend`, so its methods become class methods on
  # the host (e.g. `AtlasRb::Work.connection({})`).
  module FaradayHelper
    # ActiveSupport::Notifications event name emitted per outbound Atlas request.
    # A dedicated name (not Faraday's default `request.faraday`) so a host that
    # also uses Faraday for other clients can subscribe to Atlas traffic alone.
    INSTRUMENTATION_EVENT = "request.atlas_rb"
    # Wire contract Atlas enforces for relay-signing assertions (see Atlas
    # ApplicationController#verify_cerberus_assertion). iss/aud are fixed; the
    # short TTL bounds replay (Atlas allows 30s leeway on exp).
    ASSERTION_ISSUER   = "cerberus"
    ASSERTION_AUDIENCE = "atlas"
    ASSERTION_TTL      = 30 # seconds
    # Build a JSON-content Faraday connection to the Atlas API.
    #
    # @param params [Hash] query-string / body params to attach to the request.
    #   Resource classes use this to pass things like `parent_id:`, `work_id:`,
    #   or `metadata:` without manually serializing.
    # @param nuid [String, nil] optional Northeastern University ID. On the
    #   relay-signing path it is signed into the assertion `sub`. When `nil`,
    #   falls through to `AtlasRb.config.default_nuid&.call`.
    # @param on_behalf_of [String, nil] optional NUID carried as a signed `obo`
    #   claim (acting-as / view-as). When `nil`, falls through to
    #   `AtlasRb.config.default_on_behalf_of&.call`; if that is also nil, no
    #   `obo` claim is added.
    # @param account [String, nil] optional account email carried as a signed
    #   `acct` claim, naming which of the NUID's accounts is acting. When `nil`,
    #   falls through to `AtlasRb.config.default_account&.call`; if that is also
    #   nil, no `acct` claim is added and Atlas resolves the preferred account.
    # @param idempotency_key [String, nil] optional UUID to send in the
    #   `Idempotency-Key` header. Used by retry-safe create flows (currently
    #   `POST /works`, `POST /file_sets`, `POST /files`) to deduplicate replays
    #   against the originally-created resource. Generated by the caller —
    #   this gem does not mint keys.
    # @param auth [:required, :optional] auth strictness. `:required` (default)
    #   raises {AtlasRb::ConfigurationError} when no credential can be built —
    #   the right behaviour for every endpoint behind `require_auth`. `:optional`
    #   signs when it can but sends no `Authorization` header otherwise, for the
    #   handful of endpoints Atlas serves with auth skipped (currently only
    #   `GET /reset`).
    # @return [AtlasRb::Transport::Proxy] a per-request view onto the shared
    #   JSON connection, which follows redirects and pools its sockets. It
    #   answers `get` / `post` / `patch` / `put` / `delete` like a
    #   `Faraday::Connection` and forwards a block to the request.
    #
    # @example Fetching a community
    #   AtlasRb::Community.connection({}).get('/communities/abc123')
    def connection(params, nuid=nil, on_behalf_of: nil, account: nil, idempotency_key: nil, auth: :required)
      headers = auth_headers(nuid, on_behalf_of, account: account, optional: auth == :optional)
                .merge("Content-Type" => "application/json")
      headers["Idempotency-Key"] = idempotency_key if idempotency_key

      url  = ENV.fetch("ATLAS_URL", nil)
      conn = AtlasRb::Transport.connection_for([:json, url]) do
        Faraday.new(url: url) do |f|
          bound_timeouts(f, AtlasRb::Transport.read_timeout)
          retry_reads(f)
          instrument(f)
          error_middleware(f, reads: true)
          f.response :follow_redirects
          persistent_adapter(f)
        end
      end

      AtlasRb::Transport::Proxy.new(conn, headers, params)
    end

    # Build a multipart Faraday connection used for binary and XML uploads.
    #
    # The same `ATLAS_URL` env var and auth modes apply. Unlike {#connection},
    # the `Content-Type` is set automatically by the multipart middleware, and
    # callers pass a payload hash whose values may include
    # `Faraday::Multipart::FilePart` instances. Fall-through semantics for
    # `nuid` / `on_behalf_of` match {#connection}.
    #
    # @param nuid [String, nil] optional acting NUID (signed into the assertion
    #   `sub` on the relay-signing path).
    # @param on_behalf_of [String, nil] optional NUID carried as a signed `obo`
    #   claim (acting-as / view-as).
    # @param idempotency_key [String, nil] optional UUID to send in the
    #   `Idempotency-Key` header. See {#connection} for semantics; the
    #   `POST /files` (Blob) create flow uses this transport.
    # @return [AtlasRb::Transport::Proxy] a per-request view onto the shared
    #   multipart connection.
    #
    # @example Posting a binary blob
    #   payload = {
    #     work_id: "w-123",
    #     binary: Faraday::Multipart::FilePart.new(File.open("scan.pdf"),
    #                                               "application/octet-stream",
    #                                               "scan.pdf")
    #   }
    #   AtlasRb::Blob.multipart.post('/files/', payload)
    def multipart(nuid=nil, on_behalf_of: nil, account: nil, idempotency_key: nil)
      headers = auth_headers(nuid, on_behalf_of, account: account)
      headers["Idempotency-Key"] = idempotency_key if idempotency_key

      url  = ENV.fetch("ATLAS_URL", nil)
      conn = AtlasRb::Transport.connection_for([:multipart, url]) do
        Faraday.new(url: url) do |f|
          # No read deadline by default, and no retry: a multi-gigabyte upload
          # outlives any page-sized budget, and a partially-streamed POST must
          # not be replayed blindly — even under an `Idempotency-Key`, which
          # the transport cannot see.
          bound_timeouts(f, AtlasRb::Transport.upload_read_timeout)
          instrument(f)
          error_middleware(f, reads: false)
          f.request :multipart
          f.request :url_encoded
          persistent_adapter(f)
        end
      end

      AtlasRb::Transport::Proxy.new(conn, headers)
    end

    # Build a streaming multipart FilePart for `blob_path`, run the request
    # inside the block, and close the underlying File handle deterministically
    # afterward (on success or exception). The handle must stay open *during*
    # the request — Faraday reads it while posting — so it can't be closed
    # before the call; an unclosed handle leaks a descriptor per upload, which
    # exhausts FDs across a TB migration of millions of files.
    #
    # Streaming/memory: faraday-multipart wraps the part in a streaming
    # CompositeReadIO and the pinned net_http_persistent adapter sends it via
    # `request.body_stream` (Content-Length known), so a multi-GB file uploads
    # without being buffered into a String in memory. The adapter is pinned by
    # {#persistent_adapter} rather than read from `Faraday.default_adapter`, so
    # a host app's own default cannot swap a buffering adapter in underneath
    # this.
    #
    # @param blob_path [String] path to the binary on disk.
    # @yieldparam part [Faraday::Multipart::FilePart] the streaming part.
    # @return the block's return value.
    def with_file_part(blob_path)
      File.open(blob_path, "rb") do |io|
        yield Faraday::Multipart::FilePart.new(io, "application/octet-stream",
                                               File.basename(blob_path))
      end
    end

    # Build a Faraday connection authenticated as the Atlas `:system`
    # fixture for system-context calls (SSO user provisioning, etc.).
    #
    # **Distinct from {#connection}.** The bearer token comes from
    # `Rails.application.credentials.atlas_system_token` (NOT `ENV` — the
    # source report's leak-halving argument: a `.env` leak shouldn't
    # expose the system token alongside the user token). The `User:`
    # header is hard-pinned to {AtlasRb::System::NUID} so this path
    # always identifies as the Atlas system principal. The configurable
    # `default_nuid` / `default_on_behalf_of` are **never** consulted —
    # there is no ambient user context on this path.
    #
    # Used exclusively by classes under {AtlasRb::System}.
    #
    # @param params [Hash] query-string / body params.
    # @param on_behalf_of [String, nil] optional NUID sent as a plain (not
    #   signed) `On-Behalf-Of` header — this path is already backend-only.
    # @return [AtlasRb::Transport::Proxy] a per-request view onto the shared
    #   system-authenticated connection.
    # @raise [RuntimeError] if the credential is not configured.
    # @raise [NameError] if `Rails` is not loaded (the gem assumes a
    #   Rails host for system-path calls).
    def system_connection(params = {}, on_behalf_of: nil)
      token = Rails.application.credentials.atlas_system_token ||
              raise("atlas_rb: Rails.application.credentials.atlas_system_token not configured")

      headers = {
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer #{token}",
        "User"          => "NUID #{AtlasRb::System::NUID}"
      }
      headers["On-Behalf-Of"] = "NUID #{on_behalf_of}" if on_behalf_of

      url  = ENV.fetch("ATLAS_URL", nil)
      conn = AtlasRb::Transport.connection_for([:system, url]) do
        Faraday.new(url: url) do |f|
          bound_timeouts(f, AtlasRb::Transport.read_timeout)
          retry_reads(f)
          instrument(f)
          error_middleware(f, reads: true)
          f.response :follow_redirects
          persistent_adapter(f)
        end
      end

      AtlasRb::Transport::Proxy.new(conn, headers, params)
    end

    # Status-guard a completed read, then parse its body.
    #
    # Every read binding funnels its response through this (or {#read_raw}) so
    # the status is consulted before the body is touched. The wire-level
    # equivalent lives in {Middleware::RaiseOnReadError}; this is the same
    # contract expressed where a binding can see it, which is what keeps the
    # guarantee true for a caller who has stubbed the transport.
    #
    # Mapping:
    #
    # - `404`             → `nil`. "Absent" is a legitimate answer to a read,
    #   and returning it as `nil` rather than an empty collection lets a caller
    #   tell "no such container" from "an empty container" — two answers that
    #   mean different things to a UI. It also covers the case where `ATLAS_URL`
    #   points at something that is not Atlas: a foreign `404` with an HTML
    #   body is a clean `nil` instead of a `JSON::ParserError` raised half a
    #   stack away from the misconfiguration that caused it.
    # - `410`             → the parsed body. A tombstone arrives as `410 Gone`
    #   *with* its full body, so it is a returnable answer.
    # - any other non-2xx → {AtlasRb::ResourceError}, naming the verb, path and
    #   status.
    # - `2xx`             → the parsed body.
    #
    # @param resp [Faraday::Response] the completed read response.
    # @yieldparam body [Hash, Array] the parsed body, when there is one.
    # @return [Object, nil] the block's value (or the parsed body with no
    #   block), or `nil` on a `404`.
    # @raise [AtlasRb::ResourceError] on a non-2xx other than `404` / `410`.
    # @api private
    def read_body(resp)
      return nil unless guard_read(resp)

      parsed = JSON.parse(resp.body)
      block_given? ? yield(parsed) : parsed
    end

    # Status-guard a completed read and hand back its body unparsed.
    #
    # The `mods` bindings' shape: Atlas renders MODS to XML/JSON/HTML
    # server-side and the body is passed through by design. That design is
    # correct for the intended payload and wrong for an error body — a
    # consumer that marks the result HTML-safe would write Atlas's failure
    # into its own page — so the status still has to be consulted first.
    # Mapping is as {#read_body}, minus the parse.
    #
    # @param resp [Faraday::Response] the completed read response.
    # @return [String, nil] the raw body, or `nil` on a `404`.
    # @raise [AtlasRb::ResourceError] on a non-2xx other than `404` / `410`.
    # @api private
    def read_raw(resp)
      return nil unless guard_read(resp)

      resp.body
    end

    private

    # True when `resp` carries a body worth reading, false on a `404`.
    #
    # @raise [AtlasRb::ResourceError] on a non-2xx other than `404` / `410`.
    def guard_read(resp)
      return false if resp.status == 404
      return true if resp.success? || resp.status == 410

      env = resp.env
      raise AtlasRb::ResourceError.new(
        "#{env&.method.to_s.upcase} #{env&.url&.path} → #{resp.status}: #{resp.body}",
        response: resp
      )
    end

    # Pin the pooling adapter on every builder. Pinned rather than taking
    # `Faraday.default_adapter`, because the saving depends on which adapter is
    # in use: the default `net_http` wraps each request in its own
    # `Net::HTTP#start` block and closes the socket after it, by design, so no
    # amount of connection caching reuses anything under it. Pinning also means
    # the streaming upload path no longer depends on what the host app happens
    # to have set as its Faraday default.
    def persistent_adapter(builder)
      builder.adapter :net_http_persistent, pool_size: AtlasRb::Transport.pool_size do |http|
        AtlasRb::Transport.configure_persistent(http)
      end
    end

    # Put a deadline on every connection the gem builds. `Net::HTTP`'s own 60s
    # defaults are a fallback rather than a considered number, and they are not
    # something a host can retrofit from outside — no amount of rescuing in the
    # consumer shortens a socket the gem owns. So the gem ships the numbers.
    #
    # `read` is passed in rather than read here, because the shapes want
    # different answers: a page read should fail inside a user's patience, a
    # binary upload legitimately runs for minutes.
    #
    # Note this is `Net::HTTP`'s per-read deadline, not a total-response
    # budget — a streaming download stays alive as long as bytes keep arriving.
    def bound_timeouts(builder, read)
      builder.options.open_timeout = AtlasRb::Transport.open_timeout
      builder.options.timeout      = read
    end

    # Register the error-translating middleware, in the one order that works.
    #
    # Faraday runs `on_complete` innermost-first, so the handler registered
    # earliest here runs *last*. That is why the generic read guard goes on
    # first: a maintenance `503` has to stay a
    # {AtlasRb::ReadOnlyModeError} and a refused re-parent a
    # {AtlasRb::ForbiddenError}, so the typed translators must get their look
    # at the status before the catch-all does. Reorder these and the typed
    # errors quietly become generic ones.
    #
    # What each one is for:
    #
    # - {Middleware::RaiseOnReadError} — the catch-all for a non-2xx read, so
    #   no binding can hand an error body back as data. `reads: false` for the
    #   multipart shape, which carries only writes.
    # - {Middleware::RaiseOnStaleResource} and
    #   {Middleware::RaiseOnResourceError} — narrowly path-scoped (see each
    #   class). Mostly no-ops on the system shape; on the multipart shape the
    #   second is what turns Atlas's verify-on-ingest `422` into a
    #   {AtlasRb::FixityMismatchError}.
    # - {Middleware::RaiseOnReadOnlyMode} — path-independent, unlike the pair
    #   above: a maintenance window refuses writes on every path and a `503`
    #   reaches neither of them. On all three shapes, because a write that
    #   slips past it silently unwraps nil and reports success.
    def error_middleware(builder, reads:)
      builder.use AtlasRb::Middleware::RaiseOnReadError if reads
      builder.use AtlasRb::Middleware::RaiseOnStaleResource
      builder.use AtlasRb::Middleware::RaiseOnResourceError
      builder.use AtlasRb::Middleware::RaiseOnReadOnlyMode
    end

    # Retry an idempotent read that failed in transport, in exactly one layer.
    #
    # Registered as the outermost handler — outside {#instrument}, so each
    # attempt is its own {INSTRUMENTATION_EVENT} rather than three attempts
    # hiding inside one event. A retried call really is two round-trips, and a
    # host counting them should see both.
    #
    # Three deliberate narrowings:
    #
    # - **`retry_statuses` is empty.** Only an exception retries; a response
    #   Atlas actually sent never does. The maintenance `503` is why: its
    #   `Retry-After` is measured in minutes, so retrying in band would ignore
    #   it and hammer the window, and {Middleware::RaiseOnReadOnlyMode} must
    #   reach the caller on the first response.
    # - **`methods` is narrower than HTTP idempotency.** `PUT` and `DELETE` are
    #   idempotent in the spec, but Atlas's `DELETE` purges an OCFL object and
    #   its `PATCH`/`PUT` writes carry optimistic-lock semantics. A replay
    #   there should be a call site's decision, not a transport default.
    # - **`Faraday::ConnectionFailed` is added explicitly.** It is not in the
    #   middleware's own default list, and it is the failure that matters most
    #   here: an Atlas restart mid-page-load is a refused connect, which one
    #   retry hides completely.
    def retry_reads(builder)
      builder.request :retry,
                      max:                 AtlasRb::Transport.read_retries,
                      interval:            0.1,
                      backoff_factor:      2,
                      interval_randomness: 0.5, # jitter, so a fleet doesn't retry in lockstep
                      max_interval:        1.0,
                      methods:             %i[get head options],
                      retry_statuses:      [],
                      exceptions:          [Faraday::ConnectionFailed,
                                            Faraday::TimeoutError,
                                            Errno::ECONNREFUSED,
                                            Errno::ECONNRESET,
                                            Errno::ETIMEDOUT,
                                            EOFError]
    end

    # Register Faraday's instrumentation middleware so each logical call emits
    # exactly one {INSTRUMENTATION_EVENT} — a redirect hop (e.g. the
    # `/resources/:noid` resolver) is bracketed with the request it redirects
    # to, not counted twice. It sits directly inside {#retry_reads}, the only
    # handler above it, so a retried call emits one event per attempt: the
    # redirect folding is about one logical call, and a retry is a second
    # round-trip rather than the same one. Guarded on
    # `defined?(ActiveSupport::Notifications)` because Faraday defaults its
    # instrumenter to that constant and would `NameError` at build time on the
    # headless path where ActiveSupport isn't loaded; there, the emit is simply
    # never wired and the transport is unaffected.
    def instrument(builder)
      return unless defined?(ActiveSupport::Notifications)

      builder.request :instrumentation, name: INSTRUMENTATION_EVENT
    end

    # Build the auth + identity headers shared by {#connection} and {#multipart}.
    # Precedence: ATLAS_JWT (BYO-JWT) > relay-signing. The acting nuid /
    # on_behalf_of fall through to the configured `default_nuid` /
    # `default_on_behalf_of` callables here, once, for whichever mode applies.
    #
    # Raises {ConfigurationError} when no credential can be built — unless
    # `optional:` is set, in which case it returns no auth headers instead. That
    # is only for endpoints Atlas serves with `require_auth` skipped (`GET
    # /reset`); every normal endpoint leaves `optional` false so a
    # misconfiguration fails loudly rather than silently going unauthenticated.
    def auth_headers(nuid, on_behalf_of, account: nil, optional: false)
      jwt = ENV.fetch("ATLAS_JWT", nil)
      return { "Authorization" => "Bearer #{jwt}" } if jwt

      nuid         ||= AtlasRb.config.default_nuid&.call
      on_behalf_of ||= AtlasRb.config.default_on_behalf_of&.call
      account      ||= AtlasRb.config.default_account&.call

      headers = signed_relay_headers(nuid, on_behalf_of, account)
      return headers if headers
      return {} if optional

      raise(ConfigurationError,
            "atlas_rb: no auth configured — set ATLAS_JWT or " \
            "AtlasRb.config.assertion_signing_key (with an acting nuid to sign)")
    end

    # A signed-assertion Authorization header (sub = acting nuid), or nil when
    # signing isn't configured or there is no acting nuid to put in `sub`.
    # Acting-as is carried IN the assertion as a signed `obo` claim (Atlas
    # honours it on the assertion path; a header obo is ignored there). When a
    # NUID holds several accounts, `account` (email) rides as a signed `acct`
    # claim naming which one is acting; absent, Atlas picks the preferred.
    def signed_relay_headers(nuid, on_behalf_of, account = nil)
      return nil unless nuid

      key = assertion_signing_key
      return nil unless key

      { "Authorization" => "Bearer #{signed_assertion(nuid.to_s, key, on_behalf_of, account)}" }
    end

    # Mint a Cerberus relay assertion for `nuid`, signed ES256 with `key`. The
    # `kid` header tells Atlas which public key to verify against; iss/aud are
    # the fixed contract; the short TTL bounds replay; `jti` is forward-compat
    # for an Atlas-side one-time cache. When `on_behalf_of` is given, it rides as
    # a SIGNED `obo` claim — acting-as that can't be forged onto a stolen
    # assertion (Atlas admin-gates the operator and ignores any header obo here).
    def signed_assertion(nuid, key, on_behalf_of = nil, account = nil)
      now = Time.now.to_i
      payload = { "iss" => ASSERTION_ISSUER, "aud" => ASSERTION_AUDIENCE, "sub" => nuid,
                  "iat" => now, "exp" => now + ASSERTION_TTL, "jti" => SecureRandom.uuid,
                  "obo"  => on_behalf_of&.to_s, # obo only when acting-as
                  "acct" => account&.to_s }.compact # acct only when a specific account is named
      JWT.encode(payload, key, "ES256", { kid: assertion_signing_kid })
    end

    # Resolve the configured signing key to an OpenSSL::PKey, or nil if signing
    # is not configured. Accepts a callable (resolved per request), a PEM
    # string, or an already-built key. A PEM is parsed through
    # {AtlasRb::Transport.parsed_key}, because parsing costs several times the
    # signature it exists to produce and the key rarely changes.
    def assertion_signing_key
      raw = config_value(AtlasRb.config.assertion_signing_key)
      return nil if raw.nil?

      return raw if raw.is_a?(OpenSSL::PKey::PKey)

      AtlasRb::Transport.parsed_key(raw)
    end

    def assertion_signing_kid
      config_value(AtlasRb.config.assertion_signing_kid)
    end

    # Config slots may hold a value or a callable resolved at request time.
    def config_value(value)
      value.respond_to?(:call) ? value.call : value
    end
  end
end
