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

    # Atlas accepts a MODS write for this type. See {Resource.mods_editable?}.
    def self.mods_editable?
      true
    end

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
    #   The preview image rides beside it: `"preview"` is its URI, and
    #   `"preview_width"`, `"preview_height"` and `"preview_placeholder"` (base64
    #   of a ~16px-wide JPEG) describe it. Each is `nil` when Atlas holds none.
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
    # @param legacy_pid [String, nil] optional v1 pid the Community migrated
    #   from, such as `"neu:1"`. Admin only; anyone else gets
    #   {ForbiddenError} with `action` `"supply_legacy_pid"`. It lands on the
    #   first save, so send it here and not on a later `put_mods`. There is no
    #   way to change it after the create. Needs Atlas 0.6.279 or later.
    # @return [Hash] the created Community payload (post-update if `xml_path`
    #   was supplied).
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::LegacyPidError] if Atlas refuses the `legacy_pid:` as
    #   malformed (`422`) or held by another resource (`409`, with
    #   {LegacyPidError#holder_id}).
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
    #
    # @example The migrated repository root, which stands in for v1's neu:1
    #   AtlasRb::Community.create(nil, legacy_pid: "neu:1", nuid: admin_nuid)
    def self.create(id = nil, xml_path = nil, nuid: nil, on_behalf_of: nil, depositor: nil, legacy_pid: nil)
      params = { parent_id: id }
      params[:depositor]  = depositor  if depositor
      params[:legacy_pid] = legacy_pid if legacy_pid
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

    # Search the Works beneath a Community, at any depth, with filters and facet
    # counts.
    #
    # Wraps `GET /communities/<id>/search`. The rows are the same Work digests
    # {Resource.descendant_works} returns, gated to what the caller may read.
    #
    # **Embargoed, in-progress and incomplete Works never appear, for any
    # caller.** That includes an admin token: the route is a public feed. Use
    # {Resource.descendant_works} or {Compilation.contents} to see them.
    #
    # @param id [String] the Community ID.
    # @param q [String, nil] keyword query; `nil` lists the whole scope.
    # @param filters [Hash{String => String, Array<String>}] field to values,
    #   e.g. `{ "genre_ssim" => ["Photographs"] }`. Values in one field match
    #   any; every field must match. Sent as `f[field][]=value`.
    # @param facets [Array<String>] the fields to count values for. Sent as
    #   `facet[]=field`.
    # @param facet_limit [Integer, nil] values per facet (Atlas: default 20, at
    #   most 100).
    # @param sort [String, nil] `"relevance"`, `"title"` or `"date"` (newest
    #   first). Atlas sorts by relevance when `q` is given, and by a stable
    #   order otherwise.
    # @param page [Integer, nil] 1-based page (default 1).
    # @param per_page [Integer, nil] page size (default 25, at most 100).
    # @param include_linked [Boolean, nil] also search Works linked into the
    #   subtree from elsewhere when truthy; structural members only by default.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash, nil] `{ "works" => [...], "pagination" => {...},
    #   "facets" => { "genre_ssim" => [{ "value", "count" }] } }`. The counts
    #   cover the whole result, not just the page. `nil` when Atlas answers `404`.
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` / `410`.
    #   A `400` means a facet or filter field Atlas does not allow, or an
    #   unknown sort; the error's message carries Atlas's explanation.
    # @example
    #   page = AtlasRb::Community.search("x-123", filters: { "genre_ssim" => ["Maps"] }, sort: "title")
    #   page.works.map(&:noid)
    def self.search(id, q: nil, filters: {}, facets: [], facet_limit: nil, sort: nil,
                    page: nil, per_page: nil, include_linked: nil, nuid: nil, on_behalf_of: nil)
      params = scoped_search_params(q: q, filters: filters, facets: facets, facet_limit: facet_limit,
                                    sort: sort, page: page, per_page: per_page)
      params[:include_linked] = include_linked unless include_linked.nil?
      read_body(connection(params, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/search')) do |body|
        AtlasRb::Mash.new(body)
      end
    end
  end
end
