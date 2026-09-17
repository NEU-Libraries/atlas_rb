# frozen_string_literal: true

module AtlasRb
  # A top-level grouping in the Atlas hierarchy.
  #
  # Communities are organizational containers — they hold {Collection}s and,
  # optionally, sub-Communities. Most institutional structure (departments,
  # programs, projects) is modeled as a tree of Communities with Collections
  # at the leaves.
  #
  # See also: {Collection}, {Work}.
  class Community < Resource
    # Atlas REST endpoint prefix for this resource.
    # @api private
    ROUTE = "/communities/"

    # Fetch a single Community by ID.
    #
    # @param id [String] the Community ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash, nil] the `"community"` object from the JSON response,
    #   already unwrapped, or `nil` when the Community does not exist (`404`).
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` / `410` (e.g. an
    #   auth/validation error envelope), carrying Atlas's status + body.
    #
    # @example
    #   AtlasRb::Community.find("c-123")
    #   # => { "id" => "c-123", "title" => "College of Engineering", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      body = fetch_resource(ROUTE + id, nuid: nuid, on_behalf_of: on_behalf_of)
      body && AtlasRb::Mash.new(body)["community"]
    end

    # Create a new Community, optionally seeded with MODS metadata.
    #
    # Pass `id = nil` to create a top-level Community; pass a Community ID to
    # nest the new Community beneath an existing one.
    #
    # @param id [String, nil] the parent Community ID, or `nil` for a
    #   top-level Community.
    # @param xml_path [String, nil] optional path to a MODS XML file. When
    #   given, the Community is created and immediately patched with the
    #   metadata in the file; the returned Hash reflects the patched state.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @param depositor [String, nil] NUID to stamp as the Community's
    #   intellectual owner. Omit it and Atlas falls through to the acting user.
    #   Supply it to attribute a container to someone other than whoever is
    #   authorizing the call — e.g. seeding an institutional tree as an admin
    #   while attributing it to the anonymous NUID, since nobody personally owns
    #   those containers and access to them is via Grouper groups. The depositor
    #   is immutable post-create; there is no setter on the update surface.
    # @return [Hash] the created Community payload (post-update if `xml_path`
    #   was supplied).
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example Top-level community, no metadata
    #   AtlasRb::Community.create(nil)
    #
    # @example Sub-community seeded from MODS
    #   AtlasRb::Community.create("c-parent", "/tmp/dept-mods.xml")
    #
    # @example An institutional container owned by nobody
    #   AtlasRb::Community.create("c-parent", depositor: "000000099")
    def self.create(id = nil, xml_path = nil, nuid: nil, on_behalf_of: nil, depositor: nil)
      params = { parent_id: id }
      params[:depositor] = depositor if depositor
      result = AtlasRb::Mash.new(write_resource(
        connection(params, nuid, on_behalf_of: on_behalf_of).post(ROUTE)
      ))["community"]
      return result if xml_path.to_s.empty?

      # The MODS seed is a second call: create takes the parent and the
      # provenance slots, and the document goes through the write that owns it.
      AtlasRb::Resource.put_mods(result["id"], xml_path, nuid: nuid, on_behalf_of: on_behalf_of)
      find(result["id"], nuid: nuid, on_behalf_of: on_behalf_of)
    end

    # List the immediate children (sub-Communities and Collections) of a Community.
    #
    # The endpoint returns just the noids; resolve each through
    # {Resource.find} (which dispatches by type) when richer payloads are
    # needed.
    #
    # @param id [String] the parent Community ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # `children` answers noids only. To render them, resolve the whole list in
    # one call with {AtlasRb::Resource.find_many}, which returns a
    # title/thumbnail digest per id — calling `find` per noid costs a
    # round-trip per child. For a whole subtree flattened to Works, use
    # {AtlasRb::Resource.descendant_works}.
    #
    # @return [Array<String>, nil] child noids from `GET /communities/<id>/children`.
    #
    #   `nil` when Atlas answers `404` — nothing is there to read, or, with a
    #   misconfigured `ATLAS_URL`, the route is not Atlas's at all.
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` / `410`
    #   (an auth or validation envelope, a `5xx`, a proxy's `503`), carrying
    #   Atlas's status and body so the failure is attributable at the boundary.
    # @example
    #   AtlasRb::Community.children("c-123")
    #   # => ["fn106x926", "kw52j804p"]
    def self.children(id, nuid: nil, on_behalf_of: nil)
      read_body(connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/children'))
    end

    # Fetch the Community's MODS representation in the requested format.
    #
    # @param id [String] the Community ID.
    # @param kind [String, nil] one of `"json"` (default when omitted),
    #   `"html"`, or `"xml"`. When `nil`, Atlas returns its default
    #   representation.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [String, nil] the raw response body (JSON, HTML, or XML serialized
    #   as a string).
    #
    #   `nil` when Atlas answers `404` — nothing is there to read, or, with a
    #   misconfigured `ATLAS_URL`, the route is not Atlas's at all.
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` / `410`
    #   (an auth or validation envelope, a `5xx`, a proxy's `503`), carrying
    #   Atlas's status and body so the failure is attributable at the boundary.
    # @example HTML rendering for display
    #   AtlasRb::Community.mods("c-123", "html")
    def self.mods(id, kind = nil, nuid: nil, on_behalf_of: nil)
      # json default, html, xml
      read_raw(connection({}, nuid, on_behalf_of: on_behalf_of).get(
                 ROUTE + id + '/mods' + (kind.to_s.empty? ? '' : ".#{kind}")
               ))
    end
  end
end
