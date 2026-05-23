# frozen_string_literal: true

module AtlasRb
  # Holds gem-wide configuration registered via {AtlasRb.configure}.
  #
  # The configuration model is deliberately tiny: two slots, both of which
  # accept callables. The gem stays consumer-agnostic — it knows nothing
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
  end
end
