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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @param depositor [String, nil] optional NUID to stamp on the new Work's
    #   `depositor` field. When omitted, Atlas defaults the depositor to the
    #   acting user (`nuid:`); this kwarg is the proxy / batch escape hatch
    #   where the librarian who uploaded the Work is distinct from the person
    #   it should be attributed to. The acting user becomes the Work's
    #   `proxy_uploader`. The depositor is immutable post-create; there is no
    #   setter on the update surface.
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
    #
    # @example Proxy deposit — librarian uploads on behalf of a researcher
    #   AtlasRb::Work.create("col-456", depositor: "000000123")
    def self.create(id, xml_path = nil, idempotency_key: nil, nuid: nil,
                    on_behalf_of: nil, depositor: nil)
      params = { collection_id: id }
      params[:depositor] = depositor if depositor
      result = AtlasRb::Mash.new(JSON.parse(
        connection(params, nuid,
                   on_behalf_of: on_behalf_of, idempotency_key: idempotency_key).post(ROUTE)&.body
      ))["work"]
      return result unless xml_path.present?

      update(result["id"], xml_path, nuid: nuid, on_behalf_of: on_behalf_of)
      find(result["id"], nuid: nuid, on_behalf_of: on_behalf_of)
    end

    # Move a Work to a different parent Collection.
    #
    # Wraps `PATCH /works/<id>/parent` with a `parent_id` of the new
    # Collection. This changes the Work's single **structural** home
    # (`a_member_of`) — distinct from {.add_linked_member}, which adds an
    # additional *linked* membership without moving the Work. Atlas
    # re-parents the Work and synchronously updates its ancestry index; the
    # structural rules (type, cycle, tombstone guards) are enforced
    # server-side and surface as a `422`.
    #
    # **Note**: like {.create}, the destination here is a **Collection**, but
    # the underlying request still uses the shared `parent_id` body key (not
    # `collection_id`) — every re-parent endpoint posts `{ parent_id }`.
    #
    # @param id [String] the Work ID to move.
    # @param new_collection_id [String] the destination Collection ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"work"` object, already unwrapped — the
    #   same shape {.find} returns, reflecting the new `a_member_of`.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    # @raise [AtlasRb::ReparentError] if Atlas rejects the move on structural
    #   grounds (HTTP 422 — `cycle`, `invalid_parent_type`, `tombstoned_node`,
    #   `tombstoned_parent`, `parent_required`, `parent_not_found`). The
    #   envelope's `error` code is exposed as `#code`.
    # @raise [AtlasRb::ForbiddenError] if Atlas refuses the move on
    #   authorization grounds (HTTP 403).
    #
    # @example
    #   AtlasRb::Work.reparent("w-789", "col-999")
    def self.reparent(id, new_collection_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ parent_id: new_collection_id }, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/parent')&.body
      ))["work"]
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
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @return [AtlasRb::Mash] the parsed JSON response.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @return [AtlasRb::Mash] the parsed JSON response.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
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

    # Store a Work's derived full-document text for search indexing.
    #
    # Purpose-specific PATCH in the same "machine-set derived metadata" family
    # as {.set_thumbnails} / {.set_image_derivatives}. Hand Atlas the Work-level
    # aggregate of the extracted body text (the concatenation of the Work's
    # content FileSets' text); Atlas stores it as the Work's derived `full_text`
    # and its `FullTextIndexer` projects it onto the Work's Solr doc
    # (`all_text_timv`) for body-text search + the "Full Text Match" snippet.
    #
    # Distinct from {.metadata} — this is a machine-extracted search aid
    # (pdftotext / Tika in a Cerberus job), not user-authored descriptive
    # content, and is re-sent on any re-ingest. Empty/blank text clears it.
    #
    # @param id [String] the Work ID.
    # @param text [String] the extracted plain text (Work-level aggregate).
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] the parsed JSON response (the Work; the stored text
    #   is not echoed back — it's read only through Solr).
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    #
    # @example
    #   AtlasRb::Work.set_full_text("w-789", text: extracted_pdf_text)
    def self.set_full_text(id, text:, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/full_text', JSON.dump(text: text))&.body
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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

    # List a Work's page FileSets in order, each with its assets.
    #
    # Wraps `GET /works/<id>/file_sets` — the ordered, grouped sibling of
    # {.assets} (which flattens FileSet membership away). One entry per
    # page-bearing FileSet, sorted `position` ascending with unordered
    # (`null`-position) FileSets last; metadata and derivative-container
    # FileSets are excluded as entries. Each entry nests its downloadable
    # assets — the page's content Blobs plus any per-page IIIF Delegates —
    # in the same polymorphic shape {.assets} returns.
    #
    # This is the read a IIIF Presentation manifest assembler needs: the
    # response is **unpaginated** by design, so the whole page sequence
    # arrives in one call.
    #
    # @param id [String] the Work ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<AtlasRb::Mash>] one entry per page FileSet, in page
    #   order: `{ "noid", "type", "position", "tombstoned", "assets" => [...] }`.
    #
    # @example Assemble manifest canvases in page order
    #   AtlasRb::Work.file_sets("w-789").each do |page|
    #     iiif = page.assets.find { |a| a["uri"] }
    #     add_canvas(order: page.position, image: iiif&.uri)
    #   end
    def self.file_sets(id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/file_sets')&.body
      ).map { |entry| AtlasRb::Mash.new(entry) }
    end

    # Fetch the Work-level METS structural metadata (page order).
    #
    # Wraps `GET /works/<id>/mets` — the JSON projection of the Work's METS
    # document, whose physical structMap is the preservation record of page
    # order. The page sequence surfaces under `"mets" => "pages"` (one entry
    # per page: `noid` / `order` / `label`). Atlas builds the document when
    # the Work is completed ({.complete}) and rebuilds it on page changes
    # thereafter, so a Work that has never been completed has no METS yet —
    # Atlas answers `404` and this binding returns `nil` (matching
    # {User.find_by_nuid}'s missing-resource convention).
    #
    # For runtime page listing (e.g. manifest assembly) prefer {.file_sets},
    # which needs no completion and carries each page's assets; this read is
    # the preservation-record view.
    #
    # @param id [String] the Work ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash, nil] the `"work"` object, already unwrapped: `{ "id",
    #   "mets" => { "created_at_iso", "agent", "files", "structure_label",
    #   "pages" => [...] } }` — or `nil` when the Work has no METS yet
    #   (never completed) or does not exist.
    #
    # @example
    #   AtlasRb::Work.mets("w-789").mets.pages.map(&:order)
    #   # => [1, 2, 3]
    def self.mets(id, nuid: nil, on_behalf_of: nil)
      response = connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/mets')
      return nil if response.status == 404

      AtlasRb::Mash.new(JSON.parse(response.body))["work"]
    end

    # Fetch the Work's MODS representation in the requested format.
    #
    # @param id [String] the Work ID.
    # @param kind [String, nil] one of `"json"` (default), `"html"`, or
    #   `"xml"`.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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

    # List the Collections a Work is a *linked* member of.
    #
    # Wraps `GET /works/<id>/linked_members`. Linked membership is the DAG
    # overlay — a Work has exactly one structural parent (`a_member_of`, set
    # by {.create} / {.reparent}) but may additionally appear in any number
    # of other Collections as a linked member (`a_linked_member_of`). This
    # returns just those linked Collection noids; the structural parent is
    # not included.
    #
    # @param id [String] the Work ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<String>] linked Collection noids (possibly empty). The
    #   shape mirrors {Collection.children} — a bare array of ids, not an
    #   envelope.
    #
    # @example
    #   AtlasRb::Work.linked_members("w-789")
    #   # => ["col-456", "col-457"]
    def self.linked_members(id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/linked_members')&.body
      )
    end

    # Add a linked membership: surface a Work in an additional Collection.
    #
    # Wraps `POST /works/<id>/linked_members` with a `collection_id` body.
    # This does **not** move the Work — its structural parent (`a_member_of`)
    # is untouched; the Collection is added to `a_linked_member_of`. Atlas
    # enforces two-sided authorization (edit on the Work *and* the target
    # Collection) and the structural guards, surfacing failures as a `422`.
    # Permissions are never changed by this call.
    #
    # @param work_id [String] the Work ID.
    # @param collection_id [String] the Collection to link the Work into.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<String>] the Work's full set of linked Collection noids
    #   *after* the add — the affected sub-resource, so no follow-up
    #   {.linked_members} GET is needed.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    # @raise [AtlasRb::LinkedMemberError] if Atlas rejects the link on
    #   structural grounds (HTTP 422). The envelope's `error` code is exposed
    #   as `#code`.
    # @raise [AtlasRb::ForbiddenError] if Atlas refuses the link on
    #   authorization grounds (HTTP 403).
    #
    # @example
    #   AtlasRb::Work.add_linked_member("w-789", "col-456")
    #   # => ["col-456"]
    def self.add_linked_member(work_id, collection_id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({ collection_id: collection_id }, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + work_id + '/linked_members')&.body
      )
    end

    # Remove a linked membership: drop a Work from an additional Collection.
    #
    # Wraps `DELETE /works/<id>/linked_members/<collection_id>` — the
    # Collection is passed as a path segment, not a body. This removes the
    # Collection from the Work's `a_linked_member_of`; the structural parent
    # (`a_member_of`) is untouched. Atlas enforces the same two-sided
    # authorization as {.add_linked_member}. Removing a link that does not
    # exist is a server-side concern; this binding simply forwards the call.
    #
    # @param work_id [String] the Work ID.
    # @param collection_id [String] the linked Collection to remove.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<String>] the Work's remaining linked Collection noids
    #   *after* the removal (possibly empty).
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    # @raise [AtlasRb::LinkedMemberError] if Atlas rejects the removal on
    #   structural grounds (HTTP 422). The envelope's `error` code is exposed
    #   as `#code`.
    # @raise [AtlasRb::ForbiddenError] if Atlas refuses the removal on
    #   authorization grounds (HTTP 403).
    #
    # @example
    #   AtlasRb::Work.remove_linked_member("w-789", "col-456")
    #   # => []
    def self.remove_linked_member(work_id, collection_id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + work_id + '/linked_members/' + collection_id)&.body
      )
    end
  end
end
