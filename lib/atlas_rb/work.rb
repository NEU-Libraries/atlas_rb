# frozen_string_literal: true

module AtlasRb
  # The bibliographic unit in Atlas — an article, thesis, dataset, image, etc.
  #
  # A Work belongs to exactly one {Collection} and aggregates one or more
  # {FileSet}s, each of which holds binary content via a {Blob}. MODS metadata
  # is attached at the Work level.
  #
  # See also: {Collection}, {FileSet}, {Blob}.
  class Work < Resource
    # Atlas REST endpoint prefix for this resource.
    # @api private
    ROUTE = "/works/"

    # Fetch a single Work by ID.
    #
    # @param id [String] the Work ID.
    # @return [Hash] the `"work"` object, already unwrapped from the JSON
    #   response.
    #
    # @example
    #   AtlasRb::Work.find("w-789")
    #   # => { "id" => "w-789", "title" => "An Article", ... }
    def self.find(id)
      AtlasRb::Mash.new(JSON.parse(connection({}).get(ROUTE + id)&.body))["work"]
    end

    # List Works, paginated.
    #
    # Wraps `GET /works`. Returns the full pagination envelope rather than a
    # bare array so callers can page through results — the shape matches
    # {AtlasRb::Community.children} and {AtlasRb::Collection.children}.
    #
    # @param in_progress [Boolean, nil] when set, filter to Works whose
    #   `in_progress` flag matches. Omit (or pass `nil`) for "all works".
    # @param page [Integer, nil] 1-indexed page number.
    # @param per_page [Integer, nil] page size override.
    # @return [AtlasRb::Mash] `{ "works" => [...], "pagination" => {...} }`.
    #   Each entry in `"works"` is a Work summary (`id`, `title`,
    #   `description`, `in_progress`).
    #
    # @example Find stuck deposits
    #   AtlasRb::Work.list(in_progress: true)
    #
    # @example Page through all works
    #   AtlasRb::Work.list(page: 2, per_page: 50)
    def self.list(in_progress: nil, page: nil, per_page: nil)
      params = {}
      params[:in_progress] = in_progress unless in_progress.nil?
      params[:page]        = page        if page
      params[:per_page]    = per_page    if per_page
      AtlasRb::Mash.new(JSON.parse(connection(params).get(ROUTE)&.body))
    end

    # Create a new Work in an existing Collection.
    #
    # **Note**: unlike {Community.create} and {Collection.create}, the `id`
    # parameter here is the parent **Collection** ID. The underlying request
    # uses the `collection_id` query param rather than `parent_id`.
    #
    # @param id [String] the parent Collection ID.
    # @param xml_path [String, nil] optional path to a MODS XML file. When
    #   given, the Work is created and immediately patched with the metadata
    #   in the file.
    # @param idempotency_key [String, nil] optional UUID. A repeat call with
    #   the same key returns the originally-created Work instead of creating
    #   a new one (or `410` if it has since been tombstoned, or `410` with
    #   no body if it has been hard-deleted). Keys are scoped to the acting
    #   user and only apply to the initial `POST /works` — the optional
    #   follow-up PATCH/GET when `xml_path` is given do not carry the key.
    #   The caller (e.g. Cerberus's Solid Queue job) generates and persists
    #   the UUID; this gem does not mint keys.
    # @return [Hash] the created Work payload (post-update if `xml_path` was
    #   supplied).
    #
    # @example Empty work, metadata to be added later
    #   AtlasRb::Work.create("col-456")
    #
    # @example Work seeded from MODS
    #   AtlasRb::Work.create("col-456", "/tmp/work-mods.xml")
    #
    # @example Retry-safe bulk-deposit create
    #   key = SecureRandom.uuid
    #   AtlasRb::Work.create("col-456", idempotency_key: key)
    def self.create(id, xml_path = nil, idempotency_key: nil)
      result = AtlasRb::Mash.new(JSON.parse(
        connection({ collection_id: id }, nil, idempotency_key: idempotency_key).post(ROUTE)&.body
      ))["work"]
      return result unless xml_path.present?

      update(result["id"], xml_path)
      find(result["id"])
    end

    # Delete a Work.
    #
    # @param id [String] the Work ID.
    # @return [Faraday::Response] the raw delete response.
    #
    # @example
    #   AtlasRb::Work.destroy("w-789")
    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    # Tombstone (withdraw) a Work.
    #
    # The Work remains in Atlas storage along with its FileSets and Blobs,
    # but is marked as withdrawn: search and show pages return a withdrawn
    # stub for every user. Unlike Communities and Collections, Works are
    # always tombstoneable regardless of how many files they hold — the
    # FileSets and Blobs ride along.
    #
    # @param id [String] the Work ID.
    # @param nuid [String] the acting user's NUID, stamped on the resource
    #   as `tombstoned_by` for audit purposes.
    # @return [Faraday::Response] the raw response.
    #
    # @example
    #   AtlasRb::Work.tombstone("w-789", nuid: "000000002")
    def self.tombstone(id, nuid:)
      connection({}, nuid).post(ROUTE + id + '/tombstone')
    end

    # Mark a Work complete.
    #
    # Cerberus's bulk-deposit job calls this once it has confirmed all
    # expected children (FileSets / Blobs) are deposited. Atlas's monitoring
    # query `GET /works?in_progress=true` then drops this Work from the
    # "stuck" list.
    #
    # Idempotent on the server: calling `complete` on an already-complete
    # Work is a no-op — Atlas simply re-saves with `in_progress: false`.
    # Atlas does not currently stamp a `completed_by` audit field; the
    # `nuid:` parameter is plumbed through for parity with the other
    # lifecycle bindings and in case Atlas adds completion audit later.
    #
    # @param id [String] the Work ID.
    # @param nuid [String, nil] optional NUID of the acting user.
    # @return [Faraday::Response] the raw response. Status `200` on success.
    #
    # @example
    #   AtlasRb::Work.complete("w-789")
    def self.complete(id, nuid: nil)
      connection({}, nuid).post(ROUTE + id + '/complete')
    end

    # Restore a previously tombstoned Work.
    #
    # **Operator-only.** Restoration is intentionally not exposed in any
    # end-user UI; call this from a Rails console session (or a future
    # admin panel) when the library has decided an object should come back.
    #
    # @param id [String] the Work ID.
    # @param nuid [String] the acting user's NUID.
    # @return [Faraday::Response] the raw response.
    #
    # @example Operator restoring from `bundle exec rails console`
    #   AtlasRb::Work.restore("w-789", nuid: "000000002")
    def self.restore(id, nuid:)
      connection({}, nuid).post(ROUTE + id + '/restore')
    end

    # Replace a Work's metadata by uploading a MODS XML document.
    #
    # @param id [String] the Work ID.
    # @param xml_path [String] path to a MODS XML file on disk.
    # @return [Hash] the parsed JSON response from the patch.
    #
    # @example
    #   AtlasRb::Work.update("w-789", "/tmp/work-mods.xml")
    def self.update(id, xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      AtlasRb::Mash.new(JSON.parse(multipart({}).patch(ROUTE + id, payload)&.body))
    end

    # Patch individual metadata fields without uploading a full MODS document.
    #
    # @param id [String] the Work ID.
    # @param values [Hash] field-level metadata updates.
    # @return [Hash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Work.metadata("w-789", title: "Revised Title")
    def self.metadata(id, values)
      AtlasRb::Mash.new(JSON.parse(connection({ metadata: values }).patch(ROUTE + id)&.body))
    end

    # List the assets attached to a Work — {Blob}s and {Delegate}s alike.
    #
    # Useful for building download UIs — the response includes enough to
    # render each entry's display name, size or `uri`, and download URL.
    # The shape is polymorphic: Blob-backed entries carry fields like
    # `size`, while Delegate-backed entries carry `uri`. Callers should
    # duck-type on the field they need rather than expecting a single
    # schema.
    #
    # @param id [String] the Work ID.
    # @return [Array<AtlasRb::Mash>] the listing from `GET /works/<id>/assets`,
    #   one entry per attached asset.
    #
    # @example
    #   AtlasRb::Work.assets("w-789").each { |a| puts a.label }
    def self.assets(id)
      JSON.parse(connection({}).get(ROUTE + id + '/assets')&.body).map { |entry| AtlasRb::Mash.new(entry) }
    end

    # @deprecated Use {.assets} instead. Will be removed in the next release.
    def self.files(id)
      assets(id)
    end

    # Fetch the Work's MODS representation in the requested format.
    #
    # @param id [String] the Work ID.
    # @param kind [String, nil] one of `"json"` (default), `"html"`, or
    #   `"xml"`.
    # @return [String] the raw response body in the requested format.
    #
    # @example
    #   AtlasRb::Work.mods("w-789", "html")
    def self.mods(id, kind = nil)
      # json default, html, xml
      connection({}).get(
        ROUTE + id + '/mods' + (kind.present? ? ".#{kind}" : '')
        )&.body
    end
  end
end
