# frozen_string_literal: true

module AtlasRb
  # A grouping of {Work}s within a {Community}.
  #
  # Collections are the leaf containers in the organizational tree — they hold
  # Works directly. Every Collection has
  # exactly one parent Community.
  #
  # See also: {Community}, {Work}.
  class Collection < Resource
    # Atlas REST endpoint prefix for this resource.
    # @api private
    ROUTE = "/collections/"

    # Fetch a single Collection by ID.
    #
    # @param id [String] the Collection ID.
    # @return [Hash] the `"collection"` object, already unwrapped from the
    #   JSON response.
    #
    # @example
    #   AtlasRb::Collection.find("col-456")
    #   # => { "id" => "col-456", "title" => "Faculty Publications", ... }
    def self.find(id)
      AtlasRb::Mash.new(JSON.parse(connection({}).get(ROUTE + id)&.body))["collection"]
    end

    # Create a new Collection under an existing Community.
    #
    # **Note**: unlike {Community.create}, the `id` parameter here is the
    # parent **Community** ID (not a parent Collection ID — Collections do
    # not nest).
    #
    # @param id [String] the parent Community ID.
    # @param xml_path [String, nil] optional path to a MODS XML file used to
    #   seed metadata. When given, the Collection is created and immediately
    #   patched with the metadata in the file.
    # @return [Hash] the created Collection payload (post-update if
    #   `xml_path` was supplied).
    #
    # @example
    #   AtlasRb::Collection.create("c-123", "/tmp/collection-mods.xml")
    def self.create(id, xml_path = nil)
      result = AtlasRb::Mash.new(JSON.parse(connection({ parent_id: id }).post(ROUTE)&.body))["collection"]
      return result unless xml_path.present?

      update(result["id"], xml_path)
      find(result["id"])
    end

    # Delete a Collection.
    #
    # @param id [String] the Collection ID.
    # @return [Faraday::Response] the raw delete response.
    #
    # @example
    #   AtlasRb::Collection.destroy("col-456")
    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    # List the Works in a Collection.
    #
    # @param id [String] the Collection ID.
    # @return [Hash] the child listing from `GET /collections/<id>/children`.
    #
    # @example
    #   AtlasRb::Collection.children("col-456")
    def self.children(id)
      AtlasRb::Mash.new(JSON.parse(connection({}).get(ROUTE + id + '/children')&.body))
    end

    # Replace a Collection's metadata by uploading a MODS XML document.
    #
    # @param id [String] the Collection ID.
    # @param xml_path [String] path to a MODS XML file on disk.
    # @return [Hash] the parsed JSON response from the patch.
    #
    # @example
    #   AtlasRb::Collection.update("col-456", "/tmp/collection-mods.xml")
    def self.update(id, xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      AtlasRb::Mash.new(JSON.parse(multipart({}).patch(ROUTE + id, payload)&.body))
    end

    # Patch individual metadata fields without uploading a full MODS document.
    #
    # @param id [String] the Collection ID.
    # @param values [Hash] field-level metadata updates.
    # @return [Hash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Collection.metadata("col-456", title: "Renamed Collection")
    def self.metadata(id, values)
      AtlasRb::Mash.new(JSON.parse(connection({ metadata: values }).patch(ROUTE + id)&.body))
    end

    # Fetch the Collection's MODS representation in the requested format.
    #
    # @param id [String] the Collection ID.
    # @param kind [String, nil] one of `"json"` (default), `"html"`, or
    #   `"xml"`.
    # @return [String] the raw response body in the requested format.
    #
    # @example
    #   AtlasRb::Collection.mods("col-456", "xml")
    def self.mods(id, kind = nil)
      # json default, html, xml
      connection({}).get(
        ROUTE + id + '/mods' + (kind.present? ? ".#{kind}" : '')
        )&.body
    end
  end
end
