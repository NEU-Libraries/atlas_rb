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
  # `ENV["ATLAS_TOKEN"]`) and pairs with a different `User:` header (always
  # {NUID}, never the acting user). Atlas's `require_auth` enforces the
  # pairing — a user token paired with the system NUID, or the system token
  # paired with a real user NUID, both 401.
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
    # the supplied NUID (creating it if missing) and replaces its
    # `groups` with the IdP-asserted set. Full replace, not merge —
    # the IdP assertion is authoritative.
    #
    # Always authenticates via {FaradayHelper#system_connection}, so the
    # caller has no way to act as a non-system principal. Atlas allows
    # this endpoint only for the system token + system NUID pairing.
    class User
      extend AtlasRb::FaradayHelper

      # Find-or-create the User keyed on NUID and replace its groups.
      #
      # @param nuid [String] the NUID of the user being provisioned.
      #   This is the *subject* of the operation, not the actor — the
      #   actor is always the system fixture.
      # @param groups [Array<String>] full group set; replaces, not merges.
      # @param name [String, nil] forwarded if the SSO callback has it;
      #   Atlas treats this field as optional.
      # @param email [String, nil] forwarded if available; optional in
      #   Atlas.
      # @return [AtlasRb::Mash] the resulting User record (`id`, `nuid`,
      #   `name`, `email`, `role`, `groups`).
      #
      # @example From Cerberus's SSO callback
      #   AtlasRb::System::User.find_or_create(
      #     nuid: "001234567",
      #     groups: ["northeastern:staff", "drs:editors"],
      #     name: "Jane Doe",
      #     email: "j.doe@example.edu"
      #   )
      def self.find_or_create(nuid:, groups:, name: nil, email: nil)
        body = { groups: groups }
        body[:name]  = name  if name
        body[:email] = email if email

        response = system_connection.put("/users/by_nuid/#{nuid}", body.to_json)
        AtlasRb::Mash.new(JSON.parse(response.body))["user"]
      end
    end
  end
end
