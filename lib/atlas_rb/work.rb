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
    # @return [Hash] the created Work payload (post-update if `xml_path` was
    #   supplied).
    #
    # @example Empty work, metadata to be added later
    #   AtlasRb::Work.create("col-456")
    #
    # @example Work seeded from MODS
    #   AtlasRb::Work.create("col-456", "/tmp/work-mods.xml")
    def self.create(id, xml_path = nil)
      result = AtlasRb::Mash.new(JSON.parse(connection({ collection_id: id }).post(ROUTE)&.body))["work"]
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

    # List the {FileSet}s and {Blob}s attached to a Work.
    #
    # Useful for building download UIs — the response includes enough to
    # render each file's display name, size, and download URL.
    #
    # @param id [String] the Work ID.
    # @return [Array<AtlasRb::Mash>] the listing from `GET /works/<id>/files`,
    #   one entry per attached file.
    #
    # @example
    #   AtlasRb::Work.files("w-789").each { |f| puts f.label }
    def self.files(id)
      JSON.parse(connection({}).get(ROUTE + id + '/files')&.body).map { |entry| AtlasRb::Mash.new(entry) }
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
