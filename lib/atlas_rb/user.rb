# frozen_string_literal: true

module AtlasRb
  # System-user binding for Atlas's find-or-create + group-replace endpoint.
  #
  # Used by Cerberus on its SSO callback: given an NUID and the IdP-asserted
  # group set, find-or-create the matching User row and replace its groups
  # with the supplied array (full replace, not merge — the IdP's assertion
  # is authoritative).
  #
  # The endpoint is system-only; {.find_or_create} sends bearer-token auth
  # and no `User:` header. Atlas returns 403 if any `User:` header is
  # present.
  class User
    extend AtlasRb::FaradayHelper

    # Find-or-create the User keyed on NUID and replace its groups.
    #
    # Idempotent on `nuid`. Authoritative on `groups`.
    #
    # @param nuid [String] the Northeastern University ID.
    # @param groups [Array<String>] full group set; replaces, not merges.
    # @param name [String, nil] forwarded if the caller (e.g. Cerberus's
    #   SSO callback) has it; Atlas treats this field as optional.
    # @param email [String, nil] forwarded if available; optional in Atlas.
    # @return [AtlasRb::Mash] the resulting User record (`id`, `nuid`,
    #   `name`, `email`, `role`, `groups`).
    #
    # @example From Cerberus's SSO callback
    #   AtlasRb::User.find_or_create(nuid: "001234567",
    #                                groups: ["northeastern:staff",
    #                                         "drs:editors"],
    #                                name: "Jane Doe",
    #                                email: "j.doe@example.edu")
    def self.find_or_create(nuid:, groups:, name: nil, email: nil)
      body = { groups: groups }
      body[:name] = name if name
      body[:email] = email if email

      response = connection({}).put("/users/by_nuid/#{nuid}", body.to_json)
      AtlasRb::Mash.new(JSON.parse(response.body))["user"]
    end
  end
end
