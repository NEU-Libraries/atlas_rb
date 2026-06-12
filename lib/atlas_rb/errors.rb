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

  # Raised when Atlas rejects a re-parent (`PATCH /<type>/:id/parent`) with a
  # structural `422` carrying a machine-readable `error` discriminator —
  # `tombstoned_node`, `tombstoned_parent`, `parent_required`,
  # `invalid_parent_type`, `cycle`, or `parent_not_found`.
  #
  # Mirrors {StaleResourceError}: a narrow translation of one wire signal
  # callers need to discriminate on. Without it the binding's `["collection"]`
  # / `["work"]` / `["community"]` unwrap silently returns `nil` on a 422,
  # discarding Atlas's `error`/`message` and leaving the caller unable to tell
  # an invalid move from a not-found from a forbidden one.
  #
  # Callers key on {#code} for specific messaging, falling back to {#message}:
  #
  #   rescue AtlasRb::ReparentError => e
  #     flash.now[:alert] = t("reparent.errors.#{e.code}", default: e.message)
  #
  # @note Authorization failures surface as {ForbiddenError} (HTTP 403), not
  #   this — even on a re-parent path.
  class ReparentError < Error
    # @return [String, nil] the machine-readable error code from the envelope
    #   (e.g. `"cycle"`), suitable for keying an i18n map.
    attr_reader :code

    # @return [String, nil] the rejected resource's ID, from the envelope.
    attr_reader :resource_id

    # @param message [String] human-readable rejection description.
    # @param code [String, nil] the envelope's `error` discriminator.
    # @param resource_id [String, nil] the rejected resource's ID.
    def initialize(message, code: nil, resource_id: nil)
      super(message)
      @code = code
      @resource_id = resource_id
    end
  end

  # Raised when Atlas rejects a linked-member write
  # (`POST` / `DELETE /works/:id/linked_members`) with a `422` carrying a
  # machine-readable `error` discriminator. The linked-member sibling of
  # {ReparentError}; same shape, same rationale (the binding would otherwise
  # discard the envelope on a non-2xx).
  #
  #   rescue AtlasRb::LinkedMemberError => e
  #     flash.now[:alert] = t("linked_member.errors.#{e.code}", default: e.message)
  #
  # @note Authorization failures surface as {ForbiddenError} (HTTP 403).
  class LinkedMemberError < Error
    # @return [String, nil] the machine-readable error code from the envelope,
    #   suitable for keying an i18n map.
    attr_reader :code

    # @return [String, nil] the rejected resource's ID, from the envelope.
    attr_reader :resource_id

    # @param message [String] human-readable rejection description.
    # @param code [String, nil] the envelope's `error` discriminator.
    # @param resource_id [String, nil] the rejected resource's ID.
    def initialize(message, code: nil, resource_id: nil)
      super(message)
      @code = code
      @resource_id = resource_id
    end
  end

  # Raised when Atlas rejects a Compilation (Set) write with a `422`
  # carrying a machine-readable `error` discriminator — a blank title on
  # create/update (`invalid_record`), or a membership add whose noid does
  # not resolve to the expected type (a Community where a Collection is
  # required, an unknown id, a Collection where a Work is required).
  #
  # The Compilation sibling of {LinkedMemberError}; same shape, same
  # rationale (the binding's `["compilation"]` unwrap would otherwise
  # discard the envelope on a non-2xx).
  #
  #   rescue AtlasRb::CompilationError => e
  #     flash.now[:alert] = e.message
  #
  # @note Authorization failures surface as {ForbiddenError} (HTTP 403).
  class CompilationError < Error
    # @return [String, nil] the machine-readable error code from the
    #   envelope (currently `"invalid_record"`).
    attr_reader :code

    # @return [String, nil] the rejected resource's ID, from the envelope
    #   (may be nil — validation envelopes don't always carry one).
    attr_reader :resource_id

    # @param message [String] human-readable rejection description.
    # @param code [String, nil] the envelope's `error` discriminator.
    # @param resource_id [String, nil] the rejected resource's ID.
    def initialize(message, code: nil, resource_id: nil)
      super(message)
      @code = code
      @resource_id = resource_id
    end
  end

  # Raised when Atlas refuses a re-parent, linked-member, or Compilation
  # request with an HTTP `403`, whose envelope is
  # `{ "error", "action", "subject" }`. Lets callers distinguish "you may
  # not do this" from a structural rejection ({ReparentError} /
  # {LinkedMemberError} / {CompilationError}) or a not-found.
  #
  # @note Scoped to the re-parent / linked-member write paths and the
  #   Compilation surface — `403`s on other endpoints still surface as raw
  #   responses for the caller's own rescue layer, unchanged.
  class ForbiddenError < Error
    # @return [String, nil] the envelope's `error` value.
    attr_reader :code

    # @return [String, nil] the action that was forbidden (e.g. `"reparent"`).
    attr_reader :action

    # @return [String, nil] the subject (resource) the action was forbidden on.
    attr_reader :subject

    # @param message [String] human-readable authorization-failure description.
    # @param code [String, nil] the envelope's `error` value.
    # @param action [String, nil] the forbidden action.
    # @param subject [String, nil] the subject the action was forbidden on.
    def initialize(message, code: nil, action: nil, subject: nil)
      super(message)
      @code = code
      @action = action
      @subject = subject
    end
  end
end
