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

  # Raised when Atlas rejects a Work-association write
  # (`POST` / `DELETE /works/:id/associations...`) with a `422` carrying a
  # machine-readable `error` discriminator — `invalid_type` (not one of the
  # five predicates), `target_not_found`, `invalid_target_type` (the target is
  # not a Work), `self_association`, `tombstoned_work`, or `tombstoned_target`.
  #
  # The association sibling of {LinkedMemberError}; same shape, same rationale
  # (the binding would otherwise discard the envelope on a non-2xx).
  #
  #   rescue AtlasRb::WorkAssociationError => e
  #     flash.now[:alert] = t("associations.errors.#{e.code}", default: e.message)
  #
  # @note Authorization failures surface as {ForbiddenError} (HTTP 403) —
  #   asserting an association is admin / devolved-admin only.
  class WorkAssociationError < Error
    # @return [String, nil] the machine-readable error code from the envelope,
    #   suitable for keying an i18n map.
    attr_reader :code

    # @return [String, nil] the rejected Work's ID, from the envelope.
    attr_reader :resource_id

    # @param message [String] human-readable rejection description.
    # @param code [String, nil] the envelope's `error` discriminator.
    # @param resource_id [String, nil] the rejected Work's ID.
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

  # Raised when Atlas rejects a binary upload's verify-on-ingest check with a
  # `422` carrying a fixity discriminator — `fixity_mismatch` (the uploaded
  # bytes don't match the supplied `expected_digest`) or
  # `unsupported_digest_algorithm` (a malformed/unknown `expected_digest`).
  # Fires on `POST /files`, `PATCH /files/:id`, and `PATCH /file_sets/:id`.
  #
  # The upload sibling of {ReparentError} / {LinkedMemberError}; same shape,
  # same rationale — without it the `["blob"]` / `["file_set"]` unwrap would
  # return `nil` on the 422 and discard the signal a migration needs to tell a
  # corrupted transfer from a clean one. Atlas rejects *before* persisting, so
  # nothing is left behind to clean up.
  #
  #   rescue AtlasRb::FixityMismatchError => e
  #     # e.code == "fixity_mismatch": re-fetch the source, retry, or quarantine
  #
  # @note Authorization failures surface as {ForbiddenError} (HTTP 403).
  class FixityMismatchError < Error
    # @return [String, nil] the machine-readable error code from the envelope
    #   (`"fixity_mismatch"` or `"unsupported_digest_algorithm"`).
    attr_reader :code

    # @return [String, nil] the rejected resource's ID, from the envelope (the
    #   FileSet on the attach path; may be nil on `POST /files`).
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

  # Raised when Atlas rejects a per-tier derivative-visibility policy
  # (`PATCH /works/:id/derivative_permissions`) with a `422` carrying a
  # machine-readable `error` discriminator — `tier_exceeds_resource` (a tier
  # more visible than its Work), `tier_ordering_violation` (visibility not
  # narrowing as resolution grows), or `unknown_tier`.
  #
  # The derivative-permissions sibling of {ReparentError} / {LinkedMemberError};
  # same shape, same rationale (the binding's `["work"]` unwrap would otherwise
  # discard the envelope on the 422). Atlas rejects before persisting.
  #
  #   rescue AtlasRb::DerivativePermissionsError => e
  #     flash.now[:alert] = t("derivative_permissions.errors.#{e.code}", default: e.message)
  #
  # @note Authorization failures surface as {ForbiddenError} (HTTP 403).
  class DerivativePermissionsError < Error
    # @return [String, nil] the machine-readable error code from the envelope,
    #   suitable for keying an i18n map.
    attr_reader :code

    # @return [String, nil] the rejected Work's ID, from the envelope.
    attr_reader :resource_id

    # @param message [String] human-readable rejection description.
    # @param code [String, nil] the envelope's `error` discriminator.
    # @param resource_id [String, nil] the rejected Work's ID.
    def initialize(message, code: nil, resource_id: nil)
      super(message)
      @code = code
      @resource_id = resource_id
    end
  end

  # Raised when Atlas refuses an ACL write on a resource
  # (`PATCH /{works,collections,communities}/:id` with `metadata[permissions]`)
  # because it breaks a rights invariant. Today the one code is
  # `visibility_exceeds_parent`: a resource may be no more visible than its
  # structural container, so opening a Work to `public` inside a restricted
  # Collection is refused (the fix is to widen the container).
  #
  # This is NOT an authorization failure — the caller may well hold full edit
  # rights on the resource, and a depositor choosing "Public" on their own item
  # under a private collection trips it in ordinary use. Without the typed
  # error the binding's `["collection"]` / `["work"]` unwrap returns an envelope
  # the caller reads as success, so the user's visibility edit is silently
  # discarded.
  #
  #   rescue AtlasRb::PermissionsError => e
  #     flash.now[:alert] = t("permissions.errors.#{e.code}", default: e.message)
  #
  # @note Keyed on the envelope's `error` code, not the request path, so other
  #   `422`s on the same endpoint (e.g. `tombstone`'s `has_live_children`) pass
  #   through untouched.
  class PermissionsError < Error
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

  # Raised when Atlas refuses a re-parent, linked-member, Compilation, or
  # container-create request with an HTTP `403`, whose envelope is
  # `{ "error", "action", "subject" }`. Lets callers distinguish "you may
  # not do this" from a structural rejection ({ReparentError} /
  # {LinkedMemberError} / {CompilationError}) or a not-found.
  #
  # On a create the `action` is `create_child` and the `subject` is the parent
  # container's class: the caller holds no edit rights on the container the new
  # child would land in.
  #
  # @note Scoped to the re-parent / linked-member write paths, the Compilation
  #   surface, and the container-create endpoints — `403`s on other endpoints
  #   still surface as raw responses for the caller's own rescue layer,
  #   unchanged.
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

  # Raised when Atlas answers a single-resource request with a non-2xx the
  # binding cannot represent as a return value:
  #
  # - on a **read** ({Resource.find} and the `Work` / `Collection` /
  #   `Community` / `FileSet` / `Person` / `Compilation` / `Blob` / `Delegate`
  #   overrides), any non-2xx that is **not** a `404` or a `410` — i.e. an error
  #   envelope (`{ "error" => ... }`, status 400/401/403/422) on what the caller
  #   treated as a plain read.
  # - on a **write** (`create`, `update`, `metadata`, and their siblings), any
  #   non-2xx at all; a `404` there is the {NotFoundError} subclass.
  #
  # Before this existed, `find` unwrapped the success body by a fixed key
  # (`["work"]`, `["collection"]`, …); on an error envelope that key is
  # absent, so `find` returned `nil` and silently discarded Atlas's status and
  # message. The caller then dereferenced the `nil` far from the cause (the
  # canonical symptom: `undefined method 'tombstoned' for nil`). This error
  # keeps the failure **at the boundary**, carrying the status and body so the
  # real cause (e.g. `… → 401: {"error":"invalid bearer token"}`) is
  # attributable everywhere `find` is used.
  #
  # On the read path a genuine `404` is **not** this — it stays a clean `nil`
  # return, since "not found" is a normal `find` outcome callers already
  # nil-check. A `410` is also **not** this — a tombstoned resource comes back
  # as `410 Gone` with its full body, which `find` returns (the caller
  # nil-checks / reads `tombstoned`), rather than an error to raise.
  #
  # @note Authorization failures on the narrow re-parent / linked-member /
  #   Compilation write paths surface as {ForbiddenError} via
  #   {Middleware::RaiseOnResourceError}; this is the catch-all for the read
  #   path, which that middleware intentionally does not cover.
  class ResourceError < Error
    # @return [Faraday::Response, nil] the originating response, when available.
    attr_reader :response

    # @return [Integer, nil] Atlas's HTTP status.
    attr_reader :status

    # @return [String, nil] Atlas's raw response body (the error envelope).
    attr_reader :body

    # @param message [String] human-readable failure description.
    # @param response [Faraday::Response, nil] the originating response; its
    #   status and body are captured for callers that rescue this.
    def initialize(message, response: nil)
      super(message)
      @response = response
      @status = response&.status
      @body = response&.body
    end
  end

  # Raised when a **write** binding (`create`, `update`, `metadata`, `parent`,
  # `rollback`, and their siblings) targets a resource Atlas answers `404` for —
  # a mistyped or foreign NOID, or one re-parented away.
  #
  # A `404` on the read path is not this: {Resource.find} and its typed
  # overrides return a clean `nil`, because "there is nothing there" answers a
  # read. It cannot answer a write — the caller asked for a change that did not
  # happen — so the write path raises instead of coercing to `nil`. Atlas
  # renders the refusal as `head :not_found` with an empty body, which is what
  # made the old blind `JSON.parse` surface it as
  # `JSON::ParserError: unexpected end of input`: a message naming neither the
  # resource nor the verb.
  #
  #   rescue AtlasRb::NotFoundError => e
  #     report.rows.failed(row, "no such object in this repository")
  #
  # A subclass of {ResourceError}, so it carries the same `status` / `body` and
  # a caller that only wants "the write failed" can rescue the parent.
  class NotFoundError < ResourceError; end

  # Raised when the transport has no way to authenticate a relay request:
  # neither `ATLAS_JWT` (BYO-JWT mode) nor a signing key
  # ({AtlasRb.config#assertion_signing_key}, relay-signing mode) is configured.
  # This is a host-misconfiguration error surfaced at request-build time, not a
  # wire response — fix the configuration rather than rescuing it.
  class ConfigurationError < Error; end
end
