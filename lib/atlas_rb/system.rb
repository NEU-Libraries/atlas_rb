# frozen_string_literal: true

module AtlasRb
  # System-context callers — see {AtlasRb::System::User} for the namespace
  # rationale (separate bearer token, hard-pinned `User:` header, the class
  # itself as the carve-out marker).
  #
  # Beyond user provisioning, the namespace exposes Atlas's operational,
  # `:system`-gated maintenance actions. These are not user operations — they
  # never appear on the human CRUD surface — so they ride the system path.
  module System
    extend AtlasRb::FaradayHelper

    # Re-project a single resource's Solr doc from Atlas's current
    # Postgres/OCFL state. Solr-only on the server — no lifecycle transition,
    # no audit event, no optimistic-lock bump. The purpose-built lever for
    # refreshing a stale projection after an indexer ships or changes (e.g.
    # the catalog's `classification_ssim` "Content" facet), without abusing
    # `AtlasRb::Work.complete` to nudge Solr as a finalize side effect.
    #
    # Idempotent. Authenticates as the Atlas `:system` fixture via
    # {FaradayHelper#system_connection}, so there is no way to issue it as a
    # regular user.
    #
    # @param id [String] the NOID of any resource (Work, Collection,
    #   Community, FileSet, ...).
    # @return [Faraday::Response] the raw response. Status `204` on success;
    #   `404` if the id does not resolve.
    #
    # @example Refresh one drifted Work after a new indexer shipped
    #   AtlasRb::System.reindex("neu:abc123")
    def self.reindex(id)
      system_connection.post("/resources/#{id}/reindex")
    end

    # Re-project a resource AND its full descendant subtree — descendant
    # containers (Collection/Community) plus the Works beneath them, a superset
    # of Atlas's re-parent cascade so Work-level projections refresh too. Same
    # Solr-only, side-effect-free semantics as {.reindex}.
    #
    # Synchronous on the server: rooted at a Collection it refreshes that
    # Collection's contents; rooted at the top Community it backfills the whole
    # repository. For a pathologically large subtree, root lower or drive the
    # cascade in chunks (repeated calls) rather than relying on Atlas to grow a
    # job runner — bulk orchestration lives in the consumer.
    #
    # @param id [String] the NOID of the subtree root.
    # @return [Integer] the number of resources re-projected (the server's
    #   `reindexed` count).
    #
    # @example Backfill a Collection's contents after an indexer change
    #   AtlasRb::System.reindex_subtree("neu:collection1")  # => 42
    def self.reindex_subtree(id)
      response = system_connection.post("/resources/#{id}/reindex_subtree")
      JSON.parse(response.body)["reindexed"]
    end

    # Record the embargoes that have lapsed. Atlas writes one `release_embargo`
    # audit row per lapsed Work, dated to the start of the release day in
    # Eastern time rather than to the call. Atlas runs no scheduler, so the
    # consumer calls this on its own schedule — Cerberus nightly.
    #
    # Idempotent: a repeat call writes nothing. Atlas looks back seven days by
    # default, so a missed night catches up on the next call.
    #
    # @param since [Date, nil] the earliest release date to consider, to widen
    #   the default seven-day window.
    # @return [Array<String>] NOIDs of the Works that gained a row on this call.
    # @raise [AtlasRb::ReadOnlyModeError] while a maintenance window is open.
    #
    # @example The nightly call
    #   AtlasRb::System.release_embargoes              # => ["abc123"]
    # @example Catch up after a long outage
    #   AtlasRb::System.release_embargoes(since: Date.new(2026, 9, 1))
    def self.release_embargoes(since: nil)
      path = since ? "/embargoes/release?since=#{since.iso8601}" : "/embargoes/release"
      JSON.parse(system_connection.post(path).body)["released"]
    end
  end
end
