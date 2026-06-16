# frozen_string_literal: true

module AtlasRb
  # The binary content backing a {FileSet} (or attached directly to a {Work}).
  #
  # Blobs are the bytes-on-disk layer of the hierarchy. Operations on this
  # class deal with raw octet streams: uploading new content, replacing
  # content on an existing Blob, and **streaming** downloads via a chunk
  # handler so very large files don't have to be buffered in memory.
  #
  # See also: {Work}, {FileSet}.
  class Blob < Resource
    # Atlas REST endpoint prefix for this resource.
    # @api private
    ROUTE = "/files/"

    # Fetch a single Blob's metadata record (not its bytes — see {.content}).
    #
    # @param id [String] the Blob ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the `"blob"` object, already unwrapped — typically
    #   includes `"id"`, `"original_filename"`, `"size"`, `"digest"` (the
    #   recorded fixity digest `"sha512:<hex>"`, or `nil` for a Blob with no
    #   held bytes — reconciliation compares this against the v1 manifest
    #   without re-downloading), and a download URL.
    #
    # @example
    #   AtlasRb::Blob.find("b-321")
    #   # => { "id" => "b-321", "original_filename" => "scan.pdf",
    #   #      "digest" => "sha512:9f86d0…", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))['blob']
    end

    # Stream the Blob's binary content through a caller-supplied block.
    #
    # The body is **not** buffered — each chunk Faraday receives is yielded
    # to `chunk_handler` immediately, making this safe for files larger than
    # available memory. The first chunk's response headers are captured and
    # returned so callers can inspect `Content-Type`, `Content-Length`, etc.
    #
    # @param id [String] the Blob ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @yieldparam chunk [String] the next chunk of binary data.
    # @return [Hash] the response headers from `GET /files/<id>/content`.
    #
    # @example Stream to disk
    #   File.open("/tmp/out.pdf", "wb") do |f|
    #     headers = AtlasRb::Blob.content("b-321") { |chunk| f.write(chunk) }
    #     puts headers["content-type"]
    #   end
    def self.content(id, nuid: nil, on_behalf_of: nil, &chunk_handler)
      headers = {}
      connection({}, nuid, on_behalf_of: on_behalf_of).get("#{ROUTE}#{id}/content") do |req|
        req.options.on_data = proc do |chunk, _bytes_received, env|
          headers = env.response_headers if headers.empty? && env
          chunk_handler.call(chunk)
        end
      end
      headers
    end

    # Upload a new Blob attached to a Work.
    #
    # `original_filename` is preserved separately from the upload's
    # `File.basename(blob_path)` because the on-disk path is often a temp
    # file name (`RackMultipart...tmp`) — Atlas needs the user-facing name
    # for download UX.
    #
    # @param id [String] the parent Work ID.
    # @param blob_path [String] path to the binary file on disk to upload.
    # @param original_filename [String] the user-facing filename Atlas
    #   should record (e.g. `"final_thesis.pdf"`).
    # @param idempotency_key [String, nil] optional UUID. A repeat call with
    #   the same key returns the originally-created Blob instead of creating
    #   a new one. See {AtlasRb::Work.create} for full semantics.
    # @param expected_digest [String, nil] optional verify-on-ingest checksum,
    #   `"<algorithm>:<hexvalue>"` (sha512/sha256/sha1/md5, e.g.
    #   `"sha256:abc…"`). Atlas hashes the uploaded bytes **before** persisting
    #   and raises {AtlasRb::FixityMismatchError} (HTTP 422) on a mismatch or an
    #   unsupported algorithm — nothing is left behind on rejection.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the created `"blob"` payload, including its `"id"` and
    #   `"digest"` (the recorded fixity digest, `"sha512:<hex>"`).
    # @raise [AtlasRb::FixityMismatchError] if `expected_digest` was supplied and
    #   the uploaded bytes did not match (or the algorithm is unsupported).
    #
    # @note Streams the file (FD closed deterministically); a multi-GB upload is
    #   not buffered in memory. See {AtlasRb::FaradayHelper#with_file_part}.
    #
    # @example
    #   AtlasRb::Blob.create("w-789", "/tmp/upload.tmp", "final_thesis.pdf")
    #   # => { "id" => "b-321", "original_filename" => "final_thesis.pdf", ... }
    #
    # @example Retry-safe bulk-deposit create with fixity verification
    #   key = SecureRandom.uuid
    #   AtlasRb::Blob.create("w-789", "/tmp/upload.tmp", "thesis.pdf",
    #                        idempotency_key: key, expected_digest: "sha256:#{sha}")
    def self.create(id, blob_path, original_filename, expected_digest: nil,
                    idempotency_key: nil, nuid: nil, on_behalf_of: nil)
      with_file_part(blob_path) do |part|
        payload = { work_id: id, original_filename: original_filename, binary: part }
        payload[:expected_digest] = expected_digest if expected_digest

        AtlasRb::Mash.new(JSON.parse(
          multipart(nuid, on_behalf_of: on_behalf_of, idempotency_key: idempotency_key)
            .post(ROUTE, payload)&.body
        ))['blob']
      end
    end

    # Delete a Blob (the bytes *and* the metadata record).
    #
    # @param id [String] the Blob ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Faraday::Response] the raw delete response.
    #
    # @example
    #   AtlasRb::Blob.destroy("b-321")
    def self.destroy(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).delete(ROUTE + id)
    end

    # Replace the bytes of an existing Blob in-place.
    #
    # The Blob ID is preserved; only the underlying content changes. The
    # original filename is *not* updated by this call — use a new
    # {.create} if you need a different `original_filename`.
    #
    # @param id [String] the Blob ID.
    # @param blob_path [String] path to the replacement binary on disk.
    # @param expected_digest [String, nil] optional verify-on-ingest checksum,
    #   `"<algorithm>:<hexvalue>"`. 422 ({AtlasRb::FixityMismatchError}) on mismatch.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the parsed JSON response from the patch (the updated
    #   `"blob"`, with a refreshed `"digest"` for the new revision).
    # @raise [AtlasRb::FixityMismatchError] if `expected_digest` was supplied and
    #   the uploaded bytes did not match (or the algorithm is unsupported).
    #
    # @note Streams the file with the FD closed deterministically — see {.create}.
    #
    # @example
    #   AtlasRb::Blob.update("b-321", "/tmp/revised.pdf")
    def self.update(id, blob_path, expected_digest: nil, nuid: nil, on_behalf_of: nil)
      with_file_part(blob_path) do |part|
        payload = { binary: part }
        payload[:expected_digest] = expected_digest if expected_digest

        AtlasRb::Mash.new(JSON.parse(
          multipart(nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id, payload)&.body
        ))
      end
    end
  end
end
