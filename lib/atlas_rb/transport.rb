# frozen_string_literal: true

module AtlasRb
  # Process-wide cache of Faraday connections, so Atlas calls reuse sockets
  # instead of paying a TCP (and, under TLS, a full TLS) handshake per request.
  #
  # ## Why a cache is needed at all
  #
  # Keep-alive is what saves the handshake, and keep-alive needs two things
  # that a per-request `Faraday.new` cannot give it. The pool lives on the
  # adapter instance, and Faraday builds a new adapter for every connection —
  # so a connection built per request gets a fresh, empty pool and reuses
  # nothing. The socket has to outlive the request, which means the connection
  # holding it has to as well.
  #
  # The cache is keyed on connection *shape* (`:json`, `:multipart`,
  # `:system`) and base URL, because those are the only things that vary at
  # build time now — per-request state (the signed assertion, the
  # `Idempotency-Key`, the query params) rides on {Proxy} instead.
  #
  # ## Why not a connection per thread
  #
  # A thread-local connection is the obvious cheap version and it is wrong for
  # this consumer: Cerberus fans out its page reads on short-lived threads, so
  # a thread-local pool dies with the thread that built it and the fan-out —
  # the calls that most want reuse — reuses nothing. `net-http-persistent`
  # keeps a shared `ConnectionPool` and uses `Thread.current` only to track
  # re-entrant checkouts, so a socket checked in by a dying thread goes back to
  # the shared stack.
  #
  # ## Thread safety
  #
  # A Faraday connection is safe for concurrent requests as long as nothing
  # mutates it after it is built. Everything here respects that: the cached
  # connection is built once under {MUTEX} (with its middleware stack forced
  # so two threads cannot race to build two adapters, and therefore two pools),
  # and per-request headers and params are set on the request, never assigned
  # onto the shared connection.
  module Transport
    # Sockets kept per host. Sized for the consumer's shape rather than left at
    # the `net-http-persistent` default (256, or a quarter of the open-file
    # limit): Cerberus draws up to four concurrent reads per Puma thread, so
    # the useful number is that fan-out times the thread count, plus headroom.
    DEFAULT_POOL_SIZE = 16

    MUTEX = Mutex.new
    # Separate from MUTEX so the key cache can never deadlock against a
    # connection build that needs a signed header.
    KEY_MUTEX = Mutex.new
    private_constant :MUTEX, :KEY_MUTEX

    # Per-request view onto a shared, cached Faraday connection.
    #
    # It exists because the state a request needs — the signed assertion (30s
    # TTL), the `Idempotency-Key`, the query params — used to be baked into the
    # connection at build time, and a connection that outlives the request
    # cannot carry any of it. The proxy holds that state and applies it to each
    # request instead.
    #
    # The caller-supplied block is forwarded, not swallowed: call sites that
    # need per-request control already use Faraday's block form (a `Range`
    # header, an `on_data` streaming handler), and those must keep working.
    # The block runs last so a call site can override anything set here.
    class Proxy
      # Per-request headers and params, exposed so a caller (and the gem's own
      # transport specs) can read what a request will send without making one.
      attr_reader :headers, :params

      # The shared connection behind this proxy, for reading its middleware
      # stack or adapter. Do not mutate it — it is shared across every request
      # of this shape, including ones in flight on other threads.
      attr_reader :connection

      # @param connection [Faraday::Connection] the shared, cached connection.
      # @param headers [Hash] per-request headers (auth, content type,
      #   idempotency key).
      # @param params [Hash] per-request query/body params.
      def initialize(connection, headers, params = {})
        @connection = connection
        @headers    = headers
        @params     = params || {}
      end

      # @!method get(path, params = nil, headers = nil, &block)
      # @!method delete(path, params = nil, headers = nil, &block)
      # Bodyless verbs — a second positional argument is query params, matching
      # `Faraday::Connection`.
      %i[get delete].each do |verb|
        define_method(verb) do |path, params = nil, headers = nil, &block|
          run(verb, path, nil, headers, params, &block)
        end
      end

      # @!method post(path, body = nil, headers = nil, &block)
      # @!method patch(path, body = nil, headers = nil, &block)
      # @!method put(path, body = nil, headers = nil, &block)
      # Body-carrying verbs — a second positional argument is the body,
      # matching `Faraday::Connection`.
      %i[post patch put].each do |verb|
        define_method(verb) do |path, body = nil, headers = nil, &block|
          run(verb, path, body, headers, nil, &block)
        end
      end

      # Escape hatch for a verb the five above don't cover, with the same
      # per-request header/param application.
      #
      # @return [Faraday::Response]
      def run_request(method, path, body, headers, &block)
        run(method, path, body, headers, nil, &block)
      end

      private

      def run(method, path, body, headers, params, &block)
        @connection.run_request(method, path, body, headers) do |req|
          req.params.update(@params) unless @params.empty?
          req.params.update(params) if params
          req.headers.update(@headers)
          block&.call(req)
        end
      end
    end

    class << self
      # Fetch the cached connection for `key`, building it from the block on
      # first use.
      #
      # @param key [Array] connection shape and base URL.
      # @yieldreturn [Faraday::Connection] a freshly built connection.
      # @return [Faraday::Connection] the shared connection for `key`.
      def connection_for(key)
        MUTEX.synchronize do
          connections[key] ||= begin
            conn = yield
            # Force the middleware stack (and with it the adapter, and with it
            # the pool) while still holding the lock. Faraday memoizes the app
            # lazily on first request, and two threads racing that memoization
            # would each build an adapter — two pools, no reuse.
            conn.builder.app
            conn
          end
        end
      end

      # Apply the pool settings a host has configured to a
      # `Net::HTTP::Persistent`. Called by the adapter's config block on every
      # request, so it must stay assignment-only and cheap.
      #
      # `max_retries` is restored to 1 here because the adapter zeroes it, and
      # zero is the wrong default for a pooled socket: a server that closed an
      # idle connection produces an error on the next write, and one retry is
      # what turns that into a reconnect instead of a caller-visible failure.
      # `Net::HTTP` gates its retry on `IDEMPOTENT_METHODS_`, so the retry-safe
      # creates (`POST /works`, `/file_sets`, `/files`) are never replayed.
      #
      # @param http [Net::HTTP::Persistent]
      # @return [void]
      def configure_persistent(http)
        http.max_retries  = 1
        http.max_requests = AtlasRb.config.connection_max_requests
      end

      # Pool size for a newly built adapter.
      #
      # @return [Integer]
      def pool_size
        AtlasRb.config.connection_pool_size || DEFAULT_POOL_SIZE
      end

      # Parse a PEM into an `OpenSSL::PKey`, reusing the last parse.
      #
      # Parsing the key costs roughly five times the ES256 signature it exists
      # to produce, and the signing key is configured as a callable returning a
      # PEM, so it was being reparsed on every request. One entry is enough —
      # the cache is a rotation check, not a store, so a rotated key parses
      # once and the old one is dropped rather than accumulating.
      #
      # @param pem [String] the PEM-encoded key.
      # @return [OpenSSL::PKey::PKey]
      def parsed_key(pem)
        KEY_MUTEX.synchronize do
          if @parsed_pem != pem
            @parsed_pem = pem
            @parsed_key = OpenSSL::PKey.read(pem)
          end
          @parsed_key
        end
      end

      # Close every pooled socket and drop the cached connections.
      #
      # Pooled sockets outliving a test example are a new source of
      # cross-example coupling, so a suite that boots and tears down a real
      # server (Atlas's `:atlas_rb_server` layer) should call this in its
      # teardown. Shutting a `net-http-persistent` pool down makes it refuse
      # later checkouts, which is why the cached connections are dropped in the
      # same breath — the next call rebuilds both.
      #
      # @return [void]
      def reset_connections!
        MUTEX.synchronize do
          connections.each_value do |conn|
            conn.close
          rescue StandardError
            # A pool already shut down, or a socket already gone, has nothing
            # left to release. The connection is being discarded either way.
            nil
          end
          connections.clear
        end
      end

      private

      def connections
        @connections ||= {}
      end
    end
  end
end
