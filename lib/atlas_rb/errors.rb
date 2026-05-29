# frozen_string_literal: true

module AtlasRb
  # Base error for atlas_rb. Subclassed for specific wire-level conditions
  # that callers want to handle distinctly. Most non-2xx responses still
  # flow through as Mashes today; we mint typed exceptions only where
  # callers genuinely need to discriminate (currently: optimistic-lock
  # conflicts that ActiveJob `retry_on` policies need to key on).
  class Error < StandardError; end

  # Raised when Atlas responds with HTTP 409 + `error: "stale_resource"`,
  # indicating an optimistic-lock conflict that either (a) exhausted
  # Atlas's internal retry budget for a retry-safe action, or (b) hit a
  # retry-unsafe action and surfaced immediately.
  #
  # Callers (typically ActiveJob subclasses in Cerberus) handle this via:
  #
  #   retry_on AtlasRb::StaleResourceError, attempts: 5, wait: :polynomially_longer
  #
  # The exception carries the resource_id and action from Atlas's envelope
  # so failure logs are useful without needing the full HTTP response.
  class StaleResourceError < Error
    # @return [String, nil] the conflicted resource's ID, from the envelope.
    attr_reader :resource_id

    # @return [String, nil] the controller action that conflicted, from the
    #   envelope (e.g. `"update_thumbnails"`).
    attr_reader :action

    # @param message [String] human-readable conflict description.
    # @param resource_id [String, nil] the conflicted resource's ID.
    # @param action [String, nil] the controller action that conflicted.
    def initialize(message, resource_id: nil, action: nil)
      super(message)
      @resource_id = resource_id
      @action = action
    end
  end
end
