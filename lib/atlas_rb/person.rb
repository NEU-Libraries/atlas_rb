# frozen_string_literal: true

module AtlasRb
  # A neutral curatorial identity in Atlas, distinct from the auth-side users
  # directory. A Person correlates the several `users` rows that share a NUID
  # and carries the authoritative, librarian-editable `display_name` (the SSO
  # `users.name` is frequently wrong and is clobbered on every login), plus
  # community affiliations.
  #
  # Addressed by NUID, not NOID — the NUID is the correlation key consumers
  # hold. So the positional `id` argument below is the person's **NUID**, and
  # the `nuid:` / `on_behalf_of:` keywords keep their usual gem meaning (the
  # acting principal). The one exception is {.create}, whose `nuid:` keyword is
  # the *new person's* NUID (matching the gap's signature); the acting principal
  # there comes from the ambient `AtlasRb.config.default_nuid`.
  #
  # Create / update / affiliation writes are :system + admin on the server; a
  # non-privileged caller gets a 403.
  class Person < Resource
    ROUTE = "/people/"

    # Fetch a Person by NUID.
    #
    # @param id [String] the person's NUID.
    # @param nuid [String, nil] acting principal (signed into the assertion sub).
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [AtlasRb::Mash] the unwrapped `"person"` object.
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))["person"]
    end

    # Batch-resolve people to their authoritative display_name in one call
    # (supersedes the SSO users directory's resolve). Unresolved NUIDs drop.
    #
    # @param nuids [Array<String>] the NUIDs to resolve.
    # @param nuid [String, nil] acting principal.
    # @param on_behalf_of [String, nil] acting-as target.
    # @return [Array<AtlasRb::Mash>] one unwrapped `"person"` per resolved NUID.
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
    # @param id [String] the person's NUID.
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
    # @param id [String] the person's NUID.
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
    # @param id [String] the person's NUID.
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
