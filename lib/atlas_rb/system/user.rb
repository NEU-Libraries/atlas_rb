# frozen_string_literal: true

module AtlasRb
  # System-context callers — calls that authenticate as the seeded Atlas
  # `:system` fixture rather than as a real user. The only client of this
  # namespace today is the SSO callback in Cerberus, which provisions /
  # refreshes the User row for a freshly-signed-in person.
  #
  # ## Why a separate namespace
  #
  # The `:system` principal needs a different bearer token (carried in
  # `Rails.application.credentials.atlas_system_token`, not the user-side
  # relay-signing / `ATLAS_JWT` credentials) and pairs with a hard-pinned
  # `User:` header (always {NUID}, never the acting user). Atlas's
  # `require_auth` enforces the pairing — the system token paired with a
  # real-user NUID is a 401.
  #
  # Routing system calls through their own class makes the carve-out
  # structural: there is no kwarg that flips a regular call into a system
  # call. The class itself is the marker.
  module System
    # The NUID of Atlas's seeded `:system` fixture. Atlas's
    # `find_by_role(:system)` returns the row with this NUID; pairing
    # validation in `require_auth` is role-based, but the seed convention
    # is stable and is the value carried in the `User:` header on every
    # {#system_connection} request.
    NUID = "000000000"

    # SSO-callback user provisioning. Finds the Atlas `User` row keyed on
    # the supplied email — the account key — (creating it if missing) and
    # replaces its `groups` with the IdP-asserted set. Full replace, not
    # merge — the IdP assertion is authoritative. Keying on email keeps a
    # person's staff/student logins as distinct accounts under one NUID.
    #
    # Always authenticates via {FaradayHelper#system_connection}, so the
    # caller has no way to act as a non-system principal. Atlas allows
    # this endpoint only for the system token + system NUID pairing.
    class User
      extend AtlasRb::FaradayHelper

      # Find-or-create the User keyed on email and replace its groups.
      #
      # Email is the account key: a person's staff and student logins share a
      # NUID but present a different email each, so keying on email keeps them
      # as distinct accounts instead of collapsing (last-write-wins) on NUID.
      #
      # @param email [String] the account key — the login's `mail`.
      #   This is the *subject* of the operation, not the actor; the actor is
      #   always the system fixture.
      # @param nuid [String, nil] the person's NUID (the grouping thread that
      #   ties a person's accounts together). Forwarded when available.
      # @param groups [Array<String>] full group set; replaces, not merges.
      # @param name [String, nil] forwarded if the SSO callback has it;
      #   Atlas treats this field as optional.
      # @param affiliation [String, nil] the login's unscoped-affiliation, a
      #   human label for the account (e.g. "staff"/"student"); optional.
      # @return [AtlasRb::Mash] the resulting User record (`id`, `nuid`,
      #   `name`, `email`, `role`, `groups`, `affiliation`, `preferred`).
      #
      # @example From Cerberus's SSO callback
      #   AtlasRb::System::User.find_or_create(
      #     email: "j.doe@northeastern.edu",
      #     nuid: "001234567",
      #     groups: ["northeastern:staff", "drs:editors"],
      #     name: "Jane Doe",
      #     affiliation: "staff"
      #   )
      def self.find_or_create(email:, nuid: nil, groups: [], name: nil, affiliation: nil)
        body = { groups: groups }
        body[:nuid]        = nuid        if nuid
        body[:name]        = name        if name
        body[:affiliation] = affiliation if affiliation

        response = system_connection.put("/users/by_email/#{email}", body.to_json)
        AtlasRb::Mash.new(JSON.parse(response.body))["user"]
      end
    end
  end
end
