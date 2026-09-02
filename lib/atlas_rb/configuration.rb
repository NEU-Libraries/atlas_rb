# frozen_string_literal: true

module AtlasRb
  # Holds gem-wide configuration registered via {AtlasRb.configure}.
  #
  # The configuration model is deliberately tiny: a handful of slots, all of
  # which accept callables. The gem stays consumer-agnostic — it knows nothing
  # about Rails, Devise, or any host application's request lifecycle — and
  # instead lets the consumer hand it lambdas that resolve the per-request
  # ambient context when a request is about to go out.
  #
  # ## Slots
  #
  # - {#default_nuid} — callable that returns the acting user's NUID when a
  #   resource method is called without an explicit `nuid:` kwarg. Typically
  #   a lambda reading from `ActiveSupport::CurrentAttributes` in a Rails
  #   host (`-> { Current.nuid }`). Set to `nil` (the default) to disable
  #   the fall-through — callers must then pass `nuid:` explicitly.
  #
  # - {#default_on_behalf_of} — callable that returns the NUID an Atlas
  #   request is being made *on behalf of*, sent as the `On-Behalf-Of:`
  #   header. Used by the acting-as / view-as feature on the consumer side.
  #   `nil` (the default) sends no header.
  #
  # ## Carve-outs
  #
  # System-path calls under {AtlasRb::System} route through
  # {FaradayHelper#system_connection}, which never consults either slot —
  # the SSO provisioning endpoint authenticates as the system fixture, not
  # as the ambient user. Admin-path calls under {AtlasRb::Admin} still
  # consult the slots (the operator is a real user) but require an
  # explicit `confirm:` kwarg as the friction marker for destructive intent.
  #
  # @example Rails host registration (typically in a config initializer)
  #   AtlasRb.configure do |config|
  #     config.default_nuid         = -> { Current.nuid }
  #     config.default_on_behalf_of = -> { Current.on_behalf_of }
  #   end
  class Configuration
    # @return [Proc, nil] callable returning the acting user's NUID, or nil
    #   to disable the fall-through.
    attr_accessor :default_nuid

    # @return [Proc, nil] callable returning the on-behalf-of NUID, or nil
    #   to send no `On-Behalf-Of:` header.
    attr_accessor :default_on_behalf_of

    # @return [Proc, nil] callable returning the ambient account email when a
    #   call is made without an explicit `account:` kwarg. A person's NUID can
    #   hold several accounts (staff/student logins); this names which one is
    #   acting, signed into the assertion as an `acct` claim (companion to
    #   {#default_nuid}). Typically `-> { Current.account_email }` in a Rails
    #   host. `nil` (the default) signs no `acct` — Atlas then resolves the
    #   person's preferred account.
    attr_accessor :default_account

    # Relay signing. When set, the regular relay path *signs* a short-lived
    # assertion (ES256, `sub` = acting nuid) — identity is proven, not asserted.
    # This is the relay credential: with no signing key configured (and no
    # `ATLAS_JWT`), the transport raises {AtlasRb::ConfigurationError}.
    #
    # Accepts either a value or a callable (resolved per request, so a Rails
    # host can read it from request-scoped state / credentials). The value may
    # be a PEM string or an `OpenSSL::PKey`; a PEM is parsed for you.
    #
    # @example Rails host (initializer), reading the EC private key from credentials
    #   AtlasRb.configure do |config|
    #     config.assertion_signing_key = -> { Rails.application.credentials.cerberus_signing_key }
    #     config.assertion_signing_kid = -> { Rails.application.credentials.cerberus_signing_kid }
    #   end
    #
    # @return [String, OpenSSL::PKey, Proc, nil] EC private key (PEM/key/callable), or nil.
    attr_accessor :assertion_signing_key

    # @return [String, Proc, nil] the `kid` stamped in the assertion header so
    #   Atlas selects the matching public key. Value or callable. Required when
    #   {#assertion_signing_key} is set.
    attr_accessor :assertion_signing_kid

    # Sockets the transport keeps open per Atlas host. Size it to the host's
    # own concurrency — a consumer that fans out N reads per request thread
    # wants N times its thread count, plus headroom — rather than to the
    # `net-http-persistent` default of 256, which is a file-descriptor budget
    # rather than a considered number. `nil` takes
    # {AtlasRb::Transport::DEFAULT_POOL_SIZE}.
    #
    # Read when a connection is first built, so set it before the first Atlas
    # call; changing it later has no effect until
    # {AtlasRb::Transport.reset_connections!}.
    #
    # @return [Integer, nil]
    attr_accessor :connection_pool_size

    # Requests to send on one pooled socket before replacing it. `nil` (the
    # default) means no cap, which is what a direct connection to Puma wants.
    # Set it when something between the client and Puma caps requests per
    # connection, because the request after that cap fails with `ECONNRESET`
    # rather than reconnecting.
    #
    # @return [Integer, nil]
    attr_accessor :connection_max_requests
  end
end
