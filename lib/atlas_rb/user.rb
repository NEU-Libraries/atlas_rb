# frozen_string_literal: true

module AtlasRb
  # Read-only user directory lookups — typeahead search and NUID → name
  # resolution.
  #
  # This is a **user-context** binding: calls authenticate as the acting
  # user via the standard `ATLAS_TOKEN` + `User:` header pairing, like every
  # other top-level class. It is deliberately *not* part of
  # {AtlasRb::System} — that namespace is structurally reserved for
  # system-token calls ({System::User.find_or_create}), and directory
  # lookups are an ordinary logged-in-user capability.
  #
  # Atlas enforces minimal disclosure: every entry carries `nuid` + `name`
  # only (no email, role, or groups), and rows with role `anonymous`,
  # `guest`, or `system` are never returned. Per the layering principle the
  # gem adds nothing on top — no caching, no name parsing, no result
  # shaping; presentation belongs to the host application.
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
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
  end
end
