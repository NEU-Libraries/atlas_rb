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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header (acting-as / view-as). Falls through to
    #   {AtlasRb.config}.default_on_behalf_of when omitted.
    # @return [Hash] the `"work"` object, already unwrapped from the JSON
    #   response.
    #
    # @example
    #   AtlasRb::Work.find("w-789")
    #   # => { "id" => "w-789", "title" => "An Article", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))["work"]
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] `{ "works" => [...], "pagination" => {...} }`.
    #   Each entry in `"works"` is a Work summary (`id`, `title`,
    #   `description`, `in_progress`).
    #
    # @example Find stuck deposits
    #   AtlasRb::Work.list(in_progress: true)
    #
    # @example Page through all works
    #   AtlasRb::Work.list(page: 2, per_page: 50)
    def self.list(in_progress: nil, page: nil, per_page: nil, nuid: nil, on_behalf_of: nil)
      params = {}
      params[:in_progress] = in_progress unless in_progress.nil?
      params[:page]        = page        if page
      params[:per_page]    = per_page    if per_page
      AtlasRb::Mash.new(JSON.parse(
        connection(params, nuid, on_behalf_of: on_behalf_of).get(ROUTE)&.body
      ))
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
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
    def self.create(id, xml_path = nil, idempotency_key: nil, nuid: nil, on_behalf_of: nil)
      result = AtlasRb::Mash.new(JSON.parse(
        connection({ collection_id: id }, nuid,
                   on_behalf_of: on_behalf_of, idempotency_key: idempotency_key).post(ROUTE)&.body
      ))["work"]
      return result unless xml_path.present?

      update(result["id"], xml_path, nuid: nuid, on_behalf_of: on_behalf_of)
      find(result["id"], nuid: nuid, on_behalf_of: on_behalf_of)
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
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Faraday::Response] the raw response.
    #
    # @example
    #   AtlasRb::Work.tombstone("w-789", nuid: "000000002")
    def self.tombstone(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).post(ROUTE + id + '/tombstone')
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
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Faraday::Response] the raw response. Status `200` on success.
    #
    # @example
    #   AtlasRb::Work.complete("w-789")
    def self.complete(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).post(ROUTE + id + '/complete')
    end

    # Replace a Work's metadata by uploading a MODS XML document.
    #
    # @param id [String] the Work ID.
    # @param xml_path [String] path to a MODS XML file on disk.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the parsed JSON response from the patch.
    #
    # @example
    #   AtlasRb::Work.update("w-789", "/tmp/work-mods.xml")
    def self.update(id, xml_path, nuid: nil, on_behalf_of: nil)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      AtlasRb::Mash.new(JSON.parse(
        multipart(nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id, payload)&.body
      ))
    end

    # Patch individual descriptive-metadata fields without uploading a
    # full MODS document.
    #
    # Scoped to user-authored descriptive metadata only. Programmatic
    # writes of machine-set Delegate URIs (thumbnails, image
    # derivatives) have their own purpose-specific endpoints — see
    # {.set_thumbnails} and {.set_image_derivatives}.
    #
    # @param id [String] the Work ID.
    # @param values [Hash] field-level metadata updates.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Work.metadata("w-789", title: "Revised Title")
    def self.metadata(id, values, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ metadata: values }, nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id)&.body
      ))
    end

    # Attach the three thumbnail/preview Delegate URIs to a Work.
    #
    # Purpose-specific PATCH for the `thumbnail_image` /
    # `thumbnail_image_2x` / `preview_image` Delegate roles. Atlas
    # dispatches each URI to its matching role via `DelegateUpdater`.
    # Distinct from {.metadata} — these are machine-set IIIF URIs, not
    # user-authored descriptive content. Missing keys are left
    # untouched server-side; only the URIs you pass are upserted.
    #
    # @param id [String] the Work ID.
    # @param thumbnail [String, nil] IIIF URI for the ~85² thumbnail.
    # @param thumbnail_2x [String, nil] IIIF URI for the ~170² 2x thumbnail.
    # @param preview [String, nil] IIIF URI for the ~500w preview image.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @return [AtlasRb::Mash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Work.set_thumbnails(
    #     "w-789",
    #     thumbnail:    "https://iiif.example.edu/iiif/3/abc.jp2/full/!85,85/0/default.jpg",
    #     thumbnail_2x: "https://iiif.example.edu/iiif/3/abc.jp2/full/!170,170/0/default.jpg",
    #     preview:      "https://iiif.example.edu/iiif/3/abc.jp2/full/500,/0/default.jpg"
    #   )
    def self.set_thumbnails(id, thumbnail: nil, thumbnail_2x: nil, preview: nil, nuid: nil, on_behalf_of: nil)
      body = { thumbnail: thumbnail, thumbnail_2x: thumbnail_2x, preview: preview }.compact
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/thumbnails', JSON.dump(body))&.body
      ))
    end

    # Attach the three image-derivative Delegate URIs to a Work.
    #
    # Sibling of {.set_thumbnails} for the `small_image` /
    # `medium_image` / `large_image` Delegate roles. Atlas dispatches
    # each URI to its matching role via `DelegateUpdater`. The
    # resulting Delegates are downloadable and surface through
    # {.assets} for the downloads UI. Missing keys are left untouched
    # server-side; only the URIs you pass are upserted.
    #
    # @param id [String] the Work ID.
    # @param small [String, nil] IIIF URI for the small derivative.
    # @param medium [String, nil] IIIF URI for the medium derivative.
    # @param large [String, nil] IIIF URI for the large derivative.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @return [AtlasRb::Mash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Work.set_image_derivatives(
    #     "w-789",
    #     small:  "https://iiif.example.edu/iiif/3/abc.jp2/full/800,/0/default.jpg",
    #     medium: "https://iiif.example.edu/iiif/3/abc.jp2/full/1600,/0/default.jpg",
    #     large:  "https://iiif.example.edu/iiif/3/abc.jp2/full/full/0/default.jpg"
    #   )
    def self.set_image_derivatives(id, small: nil, medium: nil, large: nil, nuid: nil, on_behalf_of: nil)
      body = { small: small, medium: medium, large: large }.compact
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/image_derivatives', JSON.dump(body))&.body
      ))
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<AtlasRb::Mash>] the listing from `GET /works/<id>/assets`,
    #   one entry per attached asset.
    #
    # @example
    #   AtlasRb::Work.assets("w-789").each { |a| puts a.label }
    def self.assets(id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/assets')&.body
      ).map { |entry| AtlasRb::Mash.new(entry) }
    end

    # Fetch the Work's MODS representation in the requested format.
    #
    # @param id [String] the Work ID.
    # @param kind [String, nil] one of `"json"` (default), `"html"`, or
    #   `"xml"`.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [String] the raw response body in the requested format.
    #
    # @example
    #   AtlasRb::Work.mods("w-789", "html")
    def self.mods(id, kind = nil, nuid: nil, on_behalf_of: nil)
      # json default, html, xml
      connection({}, nuid, on_behalf_of: on_behalf_of).get(
        ROUTE + id + '/mods' + (kind.present? ? ".#{kind}" : '')
        )&.body
    end
  end
end
