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
    # @return [Hash] the `"file_set"` object, already unwrapped.
    #
    # @example
    #   AtlasRb::FileSet.find("fs-001")
    def self.find(id)
      AtlasRb::Mash.new(JSON.parse(connection({}).get(ROUTE + id)&.body))["file_set"]
    end

    # Create a new FileSet under a Work.
    #
    # @param id [String] the parent Work ID.
    # @param classification [String] role tag for the FileSet — e.g.
    #   `"primary"`, `"supplemental"`, `"thumbnail"`. The exact set is
    #   defined by the Atlas server.
    # @return [Hash] the created `"file_set"` payload, including its `"id"`
    #   which can then be passed to {.update} to attach a binary.
    #
    # @example
    #   fs = AtlasRb::FileSet.create("w-789", "primary")
    #   AtlasRb::FileSet.update(fs["id"], "/tmp/article.pdf")
    def self.create(id, classification)
      AtlasRb::Mash.new(JSON.parse(connection({ work_id: id, classification: classification }).post(ROUTE)&.body))["file_set"]
    end

    # Delete a FileSet.
    #
    # @param id [String] the FileSet ID.
    # @return [Faraday::Response] the raw delete response.
    #
    # @example
    #   AtlasRb::FileSet.destroy("fs-001")
    def self.destroy(id)
      connection({}).delete(ROUTE + id)
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
    # @return [Hash] the parsed JSON response from the patch.
    #
    # @example
    #   AtlasRb::FileSet.update("fs-001", "/tmp/article.pdf")
    def self.update(id, blob_path)
      # Need to figure out blob vs XML
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                          "application/octet-stream",
                                                          File.basename(blob_path)) }
      AtlasRb::Mash.new(JSON.parse(multipart({}).patch(ROUTE + id, payload)&.body))
    end
  end
end
