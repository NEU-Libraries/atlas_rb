# frozen_string_literal: true

module AtlasRb
  # User directory lookups (typeahead search, NUID → name resolution) plus a
  # person's own account management — enumerating the accounts that share their
  # NUID and choosing a preferred (default) one.
  #
  # This is a **user-context** binding: calls authenticate as the acting
  # user via the standard relay-signing path (the acting NUID is signed into
  # the assertion `sub`), like every other top-level class. It is
  # deliberately *not* part of
  # {AtlasRb::System} — that namespace is structurally reserved for
  # system-token calls ({System::User.find_or_create}), and these are ordinary
  # logged-in-user capabilities.
  #
  # The directory lookups enforce minimal disclosure: every entry carries
  # `nuid` + `name` only (no email, role, or groups), and rows with role
  # `anonymous`, `guest`, or `system` are never returned. The account methods
  # ({.accounts} / {.set_preferred}) *do* disclose email/groups/affiliation, so
  # Atlas limits them to the person themselves (matching NUID), an admin, or the
  # system principal. Per the layering principle the gem adds nothing on top —
  # no caching, no name parsing, no result shaping; presentation belongs to the
  # host application.
  class User
    extend AtlasRb::FaradayHelper

    # Atlas REST endpoint prefix for the user directory.
    # @api private
    ROUTE = "/users"

    # Typeahead search of the user directory.
    #
    # Case-insensitive match on name, prefix match on NUID (so typing a
    # known NUID works too). Atlas caps the result (10 entries) and orders
    # it by name; a blank query resolves to an empty list.
    #
    # @param query [String] name fragment or NUID prefix to match.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @return [Array<AtlasRb::Mash>] matching directory entries, each
    #   carrying `nuid` and `name`.
    #
    # @example Recipient typeahead
    #   AtlasRb::User.search("jan", nuid: "000000002")
    #   # => [{ "nuid" => "001234567", "name" => "Doe, Jane" }, ...]
    def self.search(query, nuid: nil)
      JSON.parse(
        connection({ q: query }, nuid).get(ROUTE)&.body
      ).map { |entry| AtlasRb::Mash.new(entry) }
    end

    # Resolve a single NUID to a directory entry.
    #
    # @param target_nuid [String] the NUID being looked up — the *subject*
    #   of the call, distinct from the acting `nuid:` kwarg.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @return [AtlasRb::Mash, nil] the `nuid` + `name` entry, or `nil` when
    #   Atlas reports the NUID as absent (unknown, or held by an excluded
    #   role — the two are indistinguishable on the wire by design).
    #
    # @example Sender-name display
    #   AtlasRb::User.find_by_nuid("001234567")
    #   # => { "nuid" => "001234567", "name" => "Doe, Jane" }
    def self.find_by_nuid(target_nuid, nuid: nil)
      response = connection({}, nuid).get("#{ROUTE}/by_nuid/#{target_nuid}")
      return nil if response.status == 404

      AtlasRb::Mash.new(JSON.parse(response.body))
    end

    # Batch-resolve a set of NUIDs to directory entries in one call.
    #
    # Same response shape as {.search}. Unresolvable NUIDs (unknown or
    # excluded-role) are dropped, so the result may be shorter than the
    # input — callers index by `nuid`. Atlas caps the batch at 100.
    #
    # @param nuids [Array<String>, String] the NUIDs to resolve.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @return [Array<AtlasRb::Mash>] resolved entries, each carrying `nuid`
    #   and `name`, ordered by name.
    #
    # @example Resolve an inbox page of senders in one round-trip
    #   senders = AtlasRb::User.resolve(["001234567", "007654321"])
    #   by_nuid = senders.index_by { |entry| entry["nuid"] }
    def self.resolve(nuids, nuid: nil)
      JSON.parse(
        connection({ nuids: Array(nuids).join(",") }, nuid).get(ROUTE)&.body
      ).map { |entry| AtlasRb::Mash.new(entry) }
    end

    # List the accounts sharing a NUID — a person's staff/student logins.
    #
    # Unlike the directory lookups this discloses each account's email,
    # affiliation label, role, stored group set, and which one is preferred —
    # the data the login "you have more than one account" check and the My DRS
    # accounts panel render from. Atlas limits it to the person themselves, an
    # admin, or the system principal; others get a `403`.
    #
    # @param target_nuid [String] the NUID whose accounts to list — the
    #   *subject*, distinct from the acting `nuid:` kwarg.
    # @param nuid [String, nil] optional acting user's NUID (signed into the
    #   assertion `sub`); on the BYO-JWT path identity lives in the token.
    # @return [AtlasRb::Mash] the envelope: `nuid` plus an `accounts` array,
    #   each entry carrying `email`, `name`, `affiliation`, `role`, `groups`,
    #   and `preferred`.
    #
    # @example Login-time multi-account detection
    #   AtlasRb::User.accounts("001234567", nuid: "001234567")["accounts"].size # => 2
    def self.accounts(target_nuid, nuid: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid).get("#{ROUTE}/by_nuid/#{target_nuid}/accounts")&.body
      ))
    end

    # Set the preferred (default) account for a NUID — the account chosen when
    # a login names no specific one. Same self/admin/system scope as {.accounts}.
    #
    # @param target_nuid [String] the NUID whose default is being set.
    # @param email [String] the account to make preferred; must be one of the
    #   NUID's accounts (else Atlas returns `404`).
    # @param nuid [String, nil] optional acting user's NUID (signed into `sub`).
    # @return [AtlasRb::Mash] the updated account record under `"user"`.
    #
    # @example
    #   AtlasRb::User.set_preferred("001234567", email: "j.doe@husky.neu.edu",
    #                               nuid: "001234567")
    def self.set_preferred(target_nuid, email:, nuid: nil)
      response = connection({}, nuid)
                 .put("#{ROUTE}/by_nuid/#{target_nuid}/preferred_account", { email: email }.to_json)
      AtlasRb::Mash.new(JSON.parse(response.body))["user"]
    end
  end
end
