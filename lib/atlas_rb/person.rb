# frozen_string_literal: true

module AtlasRb
  # A neutral curatorial identity in Atlas, distinct from the auth-side users
  # directory. A Person correlates the several `users` rows that share a NUID
  # and carries the authoritative, librarian-editable `display_name` (the SSO
  # `users.name` is frequently wrong and is clobbered on every login), plus
  # community affiliations and a stable **personal-root Collection**.
  #
  # The returned Mash carries `personal_root_id` — the **NOID** of that personal
  # root, the structural parent the weighted-deposit publish conduit writes the
  # person's own Works under (then linked into a community showcase via
  # {Work.add_linked_member}). Atlas mints it eagerly at create, so it is always
  # present on a Person; read it straight off the resolve/find Mash, e.g.
  # `AtlasRb::Work.create(person["personal_root_id"], depositor: person["nuid"])`.
  #
  # Addressed by **NOID** (like Work/Collection) — the staff-facing NUID is kept
  # server-side and never put in a public URL. So the positional `id` argument
  # below is the person's **NOID**, and the `nuid:` / `on_behalf_of:` keywords
  # keep their usual gem meaning (the acting principal). NUID stays the key only
  # for {.create} (one Person per NUID — and there `nuid:` is the *new person's*
  # NUID, acting principal coming from the ambient `AtlasRb.config.default_nuid`)
  # and {.resolve} (the server-side name-resolution batch). {.list} is the
  # NOID-keyed People-index source.
  #
  # Create / update / affiliation writes are :system + admin on the server; a
  # non-privileged caller gets a 403.
  class Person < Resource
    ROUTE = "/people/"

    # Fetch a Person by NOID.
    #
    # @param id [String] the person's NOID.
    # @param nuid [String, nil] acting principal (signed into the assertion sub).
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [AtlasRb::Mash, nil] the unwrapped `"person"` object (carries the
    #   server-side `nuid` for callers that need it, e.g. depositor gating, and
    #   `personal_root_id` for the publish-conduit parent), or `nil` when the
    #   Person does not exist (`404`).
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` (e.g. an
    #   auth/validation error envelope), carrying Atlas's status + body.
    def self.find(id, nuid: nil, on_behalf_of: nil)
      body = fetch_resource(ROUTE + id, nuid: nuid, on_behalf_of: on_behalf_of)
      body && AtlasRb::Mash.new(body)["person"]
    end

    # List people — the NOID-keyed People-index source. Returns the page's
    # Persons (each with `noid`, `display_name`, the server-side `nuid`, and
    # `personal_root_id`), so a consumer builds the index and profiles entirely
    # through atlas_rb without
    # routing People through the catalog/Solr or exposing a NUID publicly.
    #
    # @param page [Integer, nil] 1-based page (server default when nil).
    # @param per_page [Integer, nil] page size (server default when nil; capped
    #   server-side).
    # @param nuid [String, nil] acting principal.
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [Array<AtlasRb::Mash>] one unwrapped `"person"` per row on the page.
    def self.list(page: nil, per_page: nil, nuid: nil, on_behalf_of: nil)
      params = { page: page, per_page: per_page }.compact
      JSON.parse(
        connection(params, nuid, on_behalf_of: on_behalf_of).get(ROUTE)&.body
      )["people"].map { |entry| AtlasRb::Mash.new(entry["person"]) }
    end

    # Batch-resolve people to their authoritative display_name in one call
    # (supersedes the SSO users directory's resolve). Unresolved NUIDs drop.
    # The deposit fork reads `affiliated_community_ids` and `personal_root_id`
    # off the same resolve Mash it already makes for the depositor's Person.
    #
    # @param nuids [Array<String>] the NUIDs to resolve.
    # @param nuid [String, nil] acting principal.
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [Array<AtlasRb::Mash>] one unwrapped `"person"` per resolved NUID
    #   (each carries `nuid`, `affiliated_community_ids`, and `personal_root_id`).
    def self.resolve(nuids, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({ nuids: Array(nuids).join(",") }, nuid, on_behalf_of: on_behalf_of).get(ROUTE)&.body
      )["people"].map { |entry| AtlasRb::Mash.new(entry["person"]) }
    end

    # Create a Person. One Person per NUID — a duplicate NUID is a 409.
    #
    # @param nuid [String] the **new person's** NUID (the subject, not the actor).
    # @param display_name [String] authoritative display name.
    # @param bio [String, nil]
    # @param orcid [String, nil]
    # @param title [String, nil]
    # @param on_behalf_of [String, nil] acting-as target (the acting principal
    #   itself comes from the ambient AtlasRb.config.default_nuid).
    # @return [AtlasRb::Mash] the unwrapped `"person"` object.
    def self.create(nuid:, display_name:, bio: nil, orcid: nil, title: nil, on_behalf_of: nil)
      body = { nuid: nuid, display_name: display_name, bio: bio, orcid: orcid, title: title }.compact
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nil, on_behalf_of: on_behalf_of).post(ROUTE, JSON.dump(body))&.body
      ))["person"]
    end

    # Edit a Person's authority fields. NUID is immutable and not patchable.
    # Only supplied fields are changed.
    #
    # @param id [String] the person's NOID.
    # @param display_name [String, nil]
    # @param bio [String, nil]
    # @param orcid [String, nil]
    # @param title [String, nil]
    # @param nuid [String, nil] acting principal.
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [AtlasRb::Mash] the unwrapped, updated `"person"` object.
    def self.update(id, display_name: nil, bio: nil, orcid: nil, title: nil, nuid: nil, on_behalf_of: nil)
      body = { display_name: display_name, bio: bio, orcid: orcid, title: title }.compact
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id, JSON.dump(body))&.body
      ))["person"]
    end

    # Add a community affiliation (idempotent; audited server-side).
    #
    # @param id [String] the person's NOID.
    # @param community_id [String] the community's NOID.
    # @param nuid [String, nil] acting principal.
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [AtlasRb::Mash] the unwrapped `"person"` object, with the updated
    #   `affiliated_community_ids`.
    def self.add_affiliation(id, community_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + id + "/affiliations", JSON.dump(community_id: community_id))&.body
      ))["person"]
    end

    # Remove a community affiliation (tolerant; audited server-side).
    #
    # @param id [String] the person's NOID.
    # @param community_id [String] the community's NOID.
    # @param nuid [String, nil] acting principal.
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [AtlasRb::Mash] the unwrapped `"person"` object.
    def self.remove_affiliation(id, community_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + id + "/affiliations/" + community_id)&.body
      ))["person"]
    end
  end
end
