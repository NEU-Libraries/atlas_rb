# frozen_string_literal: true

module AtlasRb
  # An ordered, classified slot under a {Work} that holds a {Blob}.
  #
  # FileSets give a Work multiple distinct files (e.g. a primary PDF, a
  # supplemental dataset, a thumbnail) and tag each with a `classification`
  # so the UI knows how to display it. The actual binary content lives on
  # the associated {Blob}.
  #
  # See also: {Work}, {Blob}.
  class FileSet < Resource
    # Atlas REST endpoint prefix for this resource.
    # @api private
    ROUTE = "/file_sets/"

    # Fetch a single FileSet by ID.
    #
    # @param id [String] the FileSet ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the `"file_set"` object, already unwrapped.
    #
    # @example
    #   AtlasRb::FileSet.find("fs-001")
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))["file_set"]
    end

    # Create a new FileSet under a Work.
    #
    # @param id [String] the parent Work ID.
    # @param classification [String] role tag for the FileSet — e.g.
    #   `"primary"`, `"supplemental"`, `"thumbnail"`. The exact set is
    #   defined by the Atlas server.
    # @param position [Integer, nil] optional 1-based page order within the
    #   parent Work, for multipage Works (one FileSet per page). Omit for
    #   unordered FileSets — every non-multipage FileSet stays unordered.
    #   Set at create time only; Atlas stores what it is given (sequence
    #   validation — contiguity, uniqueness — is the caller's job, e.g. the
    #   Cerberus loader rejecting bad manifests before any create).
    # @param idempotency_key [String, nil] optional UUID. A repeat call with
    #   the same key returns the originally-created FileSet instead of
    #   creating a new one. See {AtlasRb::Work.create} for full semantics.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the created `"file_set"` payload, including its `"id"`
    #   which can then be passed to {.update} to attach a binary, and its
    #   `"position"` (`nil` when unordered).
    #
    # @example
    #   fs = AtlasRb::FileSet.create("w-789", "primary")
    #   AtlasRb::FileSet.update(fs["id"], "/tmp/article.pdf")
    #
    # @example Multipage ingest — one ordered FileSet per page
    #   page = AtlasRb::FileSet.create("w-789", "image", position: 1)
    #   AtlasRb::FileSet.update(page["id"], "/tmp/page-001.tiff")
    #
    # @example Retry-safe bulk-deposit create
    #   key = SecureRandom.uuid
    #   AtlasRb::FileSet.create("w-789", "primary", idempotency_key: key)
    def self.create(id, classification, position: nil, idempotency_key: nil, nuid: nil, on_behalf_of: nil)
      params = { work_id: id, classification: classification }
      params[:position] = position if position
      AtlasRb::Mash.new(JSON.parse(
        connection(params, nuid,
                   on_behalf_of: on_behalf_of, idempotency_key: idempotency_key).post(ROUTE)&.body
      ))["file_set"]
    end

    # Delete a FileSet.
    #
    # @param id [String] the FileSet ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Faraday::Response] the raw delete response.
    #
    # @example
    #   AtlasRb::FileSet.destroy("fs-001")
    def self.destroy(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).delete(ROUTE + id)
    end

    # Attach (or replace) the binary content backing this FileSet.
    #
    # The body is uploaded as `application/octet-stream` regardless of the
    # file's true type — Atlas inspects the content server-side. To upload
    # a binary blob *plus* an original filename, use {Blob.create} directly
    # against the underlying `/files/` endpoint.
    #
    # @param id [String] the FileSet ID.
    # @param blob_path [String] path to the binary file on disk.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the parsed JSON response from the patch.
    #
    # @example
    #   AtlasRb::FileSet.update("fs-001", "/tmp/article.pdf")
    def self.update(id, blob_path, nuid: nil, on_behalf_of: nil)
      # Need to figure out blob vs XML
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                          "application/octet-stream",
                                                          File.basename(blob_path)) }
      AtlasRb::Mash.new(JSON.parse(
        multipart(nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id, payload)&.body
      ))
    end

    # Persist the per-page IIIF image-service pointer on a FileSet.
    #
    # Purpose-specific PATCH for the `service_file` Delegate role — the
    # Cantaloupe image-service base URI for this page's JP2, from which a
    # viewer derives any size on demand via `info.json`. Atlas upserts the
    # Delegate (re-setting never mints a duplicate), nesting it in a
    # `:derivative` FileSet under the page; it surfaces in the ordered
    # page listing ({Work.file_sets}) for IIIF manifest assembly.
    #
    # Sibling of {Work.set_thumbnails} / {Work.set_image_derivatives} —
    # a machine-set IIIF URI, not user-authored descriptive content.
    #
    # @param id [String] the FileSet ID.
    # @param uri [String] the IIIF image-service base URI for the page.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] the updated `"file_set"` payload.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    #
    # @example
    #   AtlasRb::FileSet.set_iiif_service(
    #     "fs-001",
    #     "https://iiif.example.edu/iiif/3/abc.jp2"
    #   )
    def self.set_iiif_service(id, uri, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + "/iiif_service", JSON.dump({ uri: uri }))&.body
      ))
    end
  end
end
