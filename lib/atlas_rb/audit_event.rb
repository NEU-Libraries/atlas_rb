# frozen_string_literal: true

module AtlasRb
  # Session-scoped AuditEvent emit — record an audit event that is **not**
  # tied to a resource write.
  #
  # ## Why this exists
  #
  # Every other AuditEvent in Atlas is a side effect of a resource mutation
  # (`create`, `update`, `tombstone`, …) and is read back per-resource via
  # {AtlasRb::Resource.history} (`GET /resources/<id>/history`). Some
  # auditable events have **no resource to hang on**: impersonation sessions.
  # An admin starting/ending an acting-as or view-as session is a security
  # event worth recording, but view-as performs no writes at all, and the
  # session lifecycle lives entirely in the calling application (a cookie),
  # so there is no resource mutation to attach the event to.
  #
  # This binding wraps Atlas's `POST /audit_events` emit endpoint, which
  # writes an AuditEvent with a **null `resource_id`** (a session-scoped
  # event). The recorded principals are passed explicitly in the body rather
  # than inferred from request headers, so the call is self-describing and
  # does not depend on the ambient {AtlasRb.config} identity being intact at
  # emit time (it may not be — e.g. an `impersonation_ended` emit fires as
  # the session is being torn down).
  #
  # ## Authorization
  #
  # The endpoint is system-token + admin-gated. The request authenticates via
  # the standard {FaradayHelper#connection} — the `Authorization: Bearer`
  # token plus a `User: NUID <admin>` header pinned to `actor_nuid` — and
  # Atlas gates the emit to admin operators. `actor_nuid` is passed
  # explicitly (rather than left to {AtlasRb.config}.default_nuid) so the
  # admin gate holds even when the ambient session identity is mid-teardown,
  # as it is for an `impersonation_ended` emit. The same `actor_nuid` is the
  # principal recorded on the event.
  #
  # @example Recording the start of an acting-as session (from Cerberus)
  #   AtlasRb::AuditEvent.emit(
  #     action:            "impersonation_started",
  #     actor_nuid:        Current.nuid,          # the admin
  #     on_behalf_of_nuid: target_nuid,           # the impersonated user
  #     mode:              "acting_as"
  #   )
  #
  # @example Recording the end of a view-as session
  #   AtlasRb::AuditEvent.emit(
  #     action:            "impersonation_ended",
  #     actor_nuid:        admin_nuid,
  #     on_behalf_of_nuid: target_nuid,
  #     mode:              "view_as"
  #   )
  class AuditEvent
    extend AtlasRb::FaradayHelper

    # Atlas REST endpoint for the session-scoped emit.
    # @api private
    ROUTE = "/audit_events"

    # Emit a session-scoped AuditEvent (one with no resource scope).
    #
    # Wraps `POST /audit_events`. The principals and metadata travel in the
    # JSON body — not in request headers — so the recorded event does not
    # depend on the ambient {AtlasRb.config} identity. The request still
    # authenticates as the configured caller (system token + the admin
    # `User:` header); Atlas admin-gates the endpoint server-side.
    #
    # Atlas stamps `occurred_at` server-side, so it is not part of the body.
    #
    # Authorization errors (`401` / `403`) are intentionally **not** caught
    # here — they surface as raw Faraday responses for the calling
    # application's rescue layer to translate, matching
    # {AtlasRb::Resource.history}.
    #
    # @param action [String] the audit action, e.g. `"impersonation_started"`
    #   or `"impersonation_ended"`.
    # @param actor_nuid [String] NUID of the principal performing the action
    #   (the admin, in the impersonation flow).
    # @param on_behalf_of_nuid [String, nil] NUID of the attribution target
    #   (the impersonated user). Omitted from the body when `nil`.
    # @param mode [String, nil] session mode, e.g. `"acting_as"` or
    #   `"view_as"`. Omitted from the body when `nil` so the binding can also
    #   carry future, mode-less session events.
    # @param payload [Hash] optional free-form metadata to record alongside
    #   the event. Omitted from the body when empty.
    # @return [AtlasRb::Mash] the parsed envelope returned by
    #   `POST /audit_events` (the created event).
    #
    # @example
    #   AtlasRb::AuditEvent.emit(
    #     action:            "impersonation_started",
    #     actor_nuid:        "000000001",
    #     on_behalf_of_nuid: "000000123",
    #     mode:              "acting_as"
    #   )
    def self.emit(action:, actor_nuid:, on_behalf_of_nuid: nil, mode: nil, payload: {})
      body = {
        action: action,
        actor_nuid: actor_nuid,
        on_behalf_of_nuid: on_behalf_of_nuid,
        mode: mode,
        payload: (payload unless payload.nil? || payload.empty?)
      }.compact

      AtlasRb::Mash.new(JSON.parse(
        connection({}, actor_nuid).post(ROUTE, JSON.dump(body))&.body
      ))
    end
  end
end
