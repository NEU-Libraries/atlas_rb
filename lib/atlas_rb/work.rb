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
    # @return [Hash, nil] the `"work"` object, already unwrapped from the JSON
    #   response, or `nil` when the Work does not exist (`404`).
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` / `410` (e.g. an
    #   auth/validation error envelope), carrying Atlas's status + body.
    #
    # @example
    #   AtlasRb::Work.find("w-789")
    #   # => { "id" => "w-789", "title" => "An Article", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      body = fetch_resource(ROUTE + id, nuid: nuid, on_behalf_of: on_behalf_of)
      body && AtlasRb::Mash.new(body)["work"]
    end

    # List Works, paginated.
    #
    # Wraps `GET /works`. Returns the full pagination envelope rather than a
    # bare array so callers can page through results — the shape matches
    # {AtlasRb::Community.children} and {AtlasRb::Collection.children}.
    #
    # @param in_progress [Boolean, nil] when set, filter to Works whose
    #   `in_progress` flag matches. Omit (or pass `nil`) for "all works".
    # @param incomplete [Boolean, nil] when set, filter to Works whose
    #   `incomplete` flag matches — the staff list of Works whose enrichment
    #   pipeline gave up (see {.mark_incomplete}). Independent of
    #   `in_progress:`, and the two combine: `in_progress: false,
    #   incomplete: true` reads as "finished, but degraded".
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
    #   `description`, `in_progress`, `incomplete`, `incomplete_reason`,
    #   `handle`). `handle` is carried on the summary, not just the detail
    #   read, so "which Works never minted?" is answerable from one page
    #   rather than a fetch per row.
    #
    # @example Find stuck deposits
    #   AtlasRb::Work.list(in_progress: true)
    #
    # @example Find works whose pipeline gave up
    #   AtlasRb::Work.list(incomplete: true)
    #
    # @example Page through all works
    #   AtlasRb::Work.list(page: 2, per_page: 50)
    def self.list(in_progress: nil, incomplete: nil, page: nil, per_page: nil, nuid: nil, on_behalf_of: nil)
      params = {}
      params[:in_progress] = in_progress unless in_progress.nil?
      params[:incomplete]  = incomplete  unless incomplete.nil?
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
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
      result = AtlasRb::Mash.new(write_resource(
        connection(params, nuid,
                   on_behalf_of: on_behalf_of, idempotency_key: idempotency_key).post(ROUTE)
      ))["work"]
      return result if xml_path.to_s.empty?

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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example
    #   AtlasRb::Work.reparent("w-789", "col-999")
    def self.reparent(id, new_collection_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(write_resource(
        connection({ parent_id: new_collection_id }, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/parent')
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
    # Work is a no-op — Atlas re-saves with `in_progress: false`.
    # Atlas does not currently stamp a `completed_by` audit field; the
    # `nuid:` parameter is plumbed through for parity with the other
    # lifecycle bindings and in case Atlas adds completion audit later.
    #
    # **This call also mints the Work's persistent identifier.** Atlas
    # registers `<prefix>/<noid>` with its Handle service, pointed at the
    # public Work page, and records it as `handle` on the Work. Two
    # consequences for a caller:
    #
    # * **Minting can never fail the call.** A handle server that is down,
    #   slow or unconfigured leaves `handle` null and the Work still
    #   complete — never a non-2xx. So a `200` does not promise a handle:
    #   the response body carries the Work, so check `handle` on it rather
    #   than assuming success minted one.
    # * **Re-completing is safe.** Atlas mints only when `handle` is empty,
    #   and the underlying registration is keyed by handle name, so a repeat
    #   call re-points rather than minting a second identifier.
    #
    # A deployment with no handle server configured mints nothing at all,
    # which is the normal state for a stack brought up without it.
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

    # Flag a Work whose enrichment pipeline gave up.
    #
    # The counterpart to {.complete}, for the other half of the lifecycle:
    # `complete` says the deposit finished, this says something downstream of
    # it did not. Call it from a work-scoped job's give-up handler — the PDF or
    # media rendition, the derivatives, the full-text extraction — once that
    # job has exhausted its retries. Atlas's `GET /works?incomplete=true` then
    # lists the Work for staff, and `incomplete_bsi` on its Solr document lets
    # a result row render a pill without a per-row fetch.
    #
    # The flag **never hides** the Work. A record with its file, title and
    # metadata but one missing derivative is degraded, not broken, and stays
    # readable — enrichment does not fail a deposit.
    #
    # Idempotent on the server; the last reason wins. Clear it with
    # {.clear_incomplete} when a later run of the same job succeeds, which
    # makes the state self-healing.
    #
    # @param id [String] the Work ID.
    # @param reason [String, nil] a machine token naming the cause — one per
    #   give-up handler, e.g. `"pdf_rendition_gave_up"`,
    #   `"media_rendition_gave_up"`, `"ingest_gave_up"`. Atlas stores it as an
    #   opaque string and does **not** validate it against a list, so the
    #   vocabulary is the caller's and a new token needs no Atlas release. Map
    #   it to display text at the point of use, with a fallback for a token the
    #   view has not been taught. A blank reason still sets the flag.
    # @param nuid [String, nil] optional NUID of the acting user.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated Work, the same shape {.find} returns, carrying
    #   `incomplete` and `incomplete_reason`.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example In a give-up handler
    #   AtlasRb::Work.mark_incomplete(work_id, reason: "pdf_rendition_gave_up")
    def self.mark_incomplete(id, reason:, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + id + '/incomplete', JSON.dump(reason: reason))
      ))["work"]
    end

    # Clear the incomplete flag and its reason.
    #
    # The repair half of {.mark_incomplete}: call it from the same job when a
    # later run succeeds, or by hand once an operator has fixed the Work. Both
    # fields clear together — a reason without a flag would leave a stale cause
    # on the Solr document.
    #
    # Idempotent: clearing a Work that was never flagged is a no-op.
    #
    # @param id [String] the Work ID.
    # @param nuid [String, nil] optional NUID of the acting user.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated Work, the same shape {.find} returns, with
    #   `incomplete` false and `incomplete_reason` null.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example On a later successful run
    #   AtlasRb::Work.clear_incomplete(work_id)
    def self.clear_incomplete(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + id + '/incomplete')
      ))["work"]
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example
    #   AtlasRb::Work.update("w-789", "/tmp/work-mods.xml")
    def self.update(id, xml_path, nuid: nil, on_behalf_of: nil)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      AtlasRb::Mash.new(write_resource(
        multipart(nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id, payload)
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example
    #   AtlasRb::Work.metadata("w-789", title: "Revised Title")
    def self.metadata(id, values, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(write_resource(
        connection({ metadata: values }, nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id)
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
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
      AtlasRb::Mash.new(write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/thumbnails', JSON.dump(body))
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
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
      AtlasRb::Mash.new(write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/image_derivatives', JSON.dump(body))
      ))
    end

    # Replace a Work's per-asset derivative-visibility policy.
    #
    # Sets which read groups may fetch each of the Work's downloadable
    # renditions, reusing the resource read-group vocabulary (`"public"`,
    # Grouper group names, `[]` = private). Two media families:
    #
    # * the image ladder `small` / `medium` / `large` / `service` (deep-zoom) /
    #   `master` (the original image), and
    # * independent media `audio` / `video` / `pdf`.
    #
    # Unlike {.set_image_derivatives} (which upserts URIs) this is a whole-object
    # REPLACE: the map you pass is the complete policy. Within the image ladder
    # omitted tiers inherit by cascade (an absent tier inherits the next
    # lower-resolution tier; `small` inherits the Work's own visibility).
    # Independent media do NOT cascade — an absent `audio`/`video`/`pdf` key
    # rides the Work. Pass a tier as `[]` to make it private.
    #
    # Atlas enforces: a tier may not be more visible than the Work, and — within
    # the image ladder — visibility must narrow as resolution grows
    # (`master` ⊆ `service` ⊆ `large` ⊆ `medium` ⊆ `small`; independent media
    # impose no ordering). The gate is advisory — it surfaces on {.assets} as
    # `gated` / `permission` for BOTH Delegate (image tier) and Blob (master /
    # pdf / audio / video, classified by media type) entries, for the display
    # layer (Cerberus / the IIIF auth service; Cerberus's download :read check)
    # to enforce.
    #
    # @param id [String] the Work ID.
    # @param policy [Hash] tier => Array(read groups), e.g.
    #   `{ large: ["northeastern:drs:repository:archives"], master: [...] }`.
    #   Keys may be strings or symbols; recognized keys are `small` / `medium` /
    #   `large` / `service` / `master` / `audio` / `video` / `pdf`.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional On-Behalf-Of NUID.
    # @return [AtlasRb::Mash] the updated Work; the stored map echoes back under
    #   `derivative_permissions`.
    # @raise [AtlasRb::DerivativePermissionsError] if Atlas rejects the policy
    #   (422) — `tier_exceeds_resource` / `tier_ordering_violation` /
    #   `unknown_tier` (see {#code}).
    # @raise [AtlasRb::StaleResourceError] on an optimistic-lock conflict (409).
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example
    #   AtlasRb::Work.set_derivative_permissions(
    #     "w-789",
    #     policy: { small:   ["public"],
    #               large:   ["northeastern:drs:repository:archives"],
    #               service: ["northeastern:drs:repository:archives"] }
    #   )
    def self.set_derivative_permissions(id, policy:, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/derivative_permissions', JSON.dump(policy))
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example
    #   AtlasRb::Work.set_full_text("w-789", text: extracted_pdf_text)
    def self.set_full_text(id, text:, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/full_text', JSON.dump(text: text))
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
    # Every entry (Blob and Delegate) also carries the advisory read gate set
    # via {.set_derivative_permissions}: `gated` (true if the asset must be
    # authorized rather than fetched directly) and `permission` (the effective
    # read-group set, or `nil` for guests, to whom group names are withheld).
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
        ROUTE + id + '/mods' + (kind.to_s.empty? ? '' : ".#{kind}")
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example
    #   AtlasRb::Work.add_linked_member("w-789", "col-456")
    #   # => ["col-456"]
    def self.add_linked_member(work_id, collection_id, nuid: nil, on_behalf_of: nil)
      write_resource(
        connection({ collection_id: collection_id }, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + work_id + '/linked_members')
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
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no such
    #   resource, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's status
    #   and body.
    #
    # @example
    #   AtlasRb::Work.remove_linked_member("w-789", "col-456")
    #   # => []
    def self.remove_linked_member(work_id, collection_id, nuid: nil, on_behalf_of: nil)
      write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + work_id + '/linked_members/' + collection_id)
      )
    end

    # The five relationship predicates Atlas accepts, carried here so a caller
    # can build a select box without hard-coding the vocabulary. Adding a sixth
    # needs an Atlas release, so this list cannot drift ahead of the server.
    ASSOCIATION_TYPES = %w[
      is_codebook_for
      is_figure_for
      is_instructional_material_for
      is_supplemental_material_for
      is_transcription_of
    ].freeze

    # List a Work's typed associations with other Works.
    #
    # Wraps `GET /works/<id>/associations`. An association is DRS v1's
    # "associated works": a directed claim that one object is the codebook,
    # figure, transcription, instructional material or supplemental material
    # **for** another. Both objects stay separate records — this is not
    # membership, and nothing moves in the containment tree.
    #
    # The edge is stored once, on the Work that asserts it. Atlas derives the
    # other direction, so `outbound` and `inbound` can never disagree.
    #
    # @param id [String] the Work ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] `{"outbound" => {predicate => [noid, …]}, "inbound" => {…}}`.
    #   `outbound` is what this Work asserts, `inbound` what other Works assert
    #   about it. Predicates holding no edges are omitted, so both maps are
    #   `{}` for an unassociated Work.
    #
    # @example
    #   AtlasRb::Work.associations("w-789")
    #   # => {"outbound" => {"is_codebook_for" => ["w-123"]}, "inbound" => {}}
    def self.associations(id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/associations')&.body
      )
    end

    # Assert that this Work stands in a typed relationship to another Work.
    #
    # Wraps `POST /works/<id>/associations` with a `work_id` + `type` body.
    # The edge is stored on **this** Work only; `target` reports the same edge
    # under `inbound`. Asserting an edge that already exists is a no-op, and
    # two Works can hold several different edges at once.
    #
    # A cycle is permitted and meaningful — "A is a transcription of B" and
    # "B is a figure for A" can both be true.
    #
    # @param work_id [String] the asserting Work's ID (the codebook, figure, …).
    # @param target_id [String] the Work being pointed at (the dataset, article, …).
    # @param type [String] one of {ASSOCIATION_TYPES}.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the Work's associations *after* the add, in the
    #   {.associations} shape — so no follow-up GET is needed.
    # @raise [AtlasRb::WorkAssociationError] if Atlas rejects the claim (HTTP
    #   422): unknown type, unresolvable target, a non-Work target, the Work
    #   itself, or either end tombstoned. The envelope's `error` code is
    #   exposed as `#code`.
    # @raise [AtlasRb::ForbiddenError] if Atlas refuses the write (HTTP 403).
    #   Associating is admin / devolved-admin only, because the claim renders
    #   on the target's page too.
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no
    #   such Work, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's
    #   status and body.
    #
    # @example
    #   AtlasRb::Work.associate("w-789", "w-123", type: "is_codebook_for")
    #   # => {"outbound" => {"is_codebook_for" => ["w-123"]}, "inbound" => {}}
    def self.associate(work_id, target_id, type:, nuid: nil, on_behalf_of: nil)
      write_resource(
        connection({ work_id: target_id, type: type }, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + work_id + '/associations')
      )
    end

    # Retract one typed relationship between two Works.
    #
    # Wraps `DELETE /works/<id>/associations/<type>/<target_id>` — the type is
    # a path segment because it is part of the edge's identity, so retracting
    # the figure claim leaves a transcription claim between the same two Works
    # standing. Idempotent: retracting an edge that was never asserted is a
    # no-op.
    #
    # @param work_id [String] the asserting Work's ID.
    # @param target_id [String] the associated Work to drop.
    # @param type [String] the predicate to retract, one of {ASSOCIATION_TYPES}.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the Work's remaining associations, in the {.associations}
    #   shape.
    # @raise [AtlasRb::WorkAssociationError] if Atlas rejects the write (HTTP
    #   422) — an unresolvable target is the usual cause here.
    # @raise [AtlasRb::ForbiddenError] if Atlas refuses the write (HTTP 403).
    # @raise [AtlasRb::NotFoundError] if Atlas answers `404` — the id names no
    #   such Work, so the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, carrying Atlas's
    #   status and body.
    #
    # @example
    #   AtlasRb::Work.disassociate("w-789", "w-123", type: "is_codebook_for")
    #   # => {"outbound" => {}, "inbound" => {}}
    def self.disassociate(work_id, target_id, type:, nuid: nil, on_behalf_of: nil)
      write_resource(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + work_id + '/associations/' + type.to_s + '/' + target_id)
      )
    end
  end
end
