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

    # Fetch a single Community by ID.
    #
    # @param id [String] the Community ID.
    # @return [Hash] the `"community"` object from the JSON response,
    #   already unwrapped.
    #
    # @example
    #   AtlasRb::Community.find("c-123")
    #   # => { "id" => "c-123", "title" => "College of Engineering", ... }
    def self.find(id)
      AtlasRb::Mash.new(JSON.parse(connection({}).get(ROUTE + id)&.body))["community"]
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
    # @return [Hash] the created Community payload (post-update if `xml_path`
    #   was supplied).
    #
    # @example Top-level community, no metadata
    #   AtlasRb::Community.create(nil)
    #
    # @example Sub-community seeded from MODS
    #   AtlasRb::Community.create("c-parent", "/tmp/dept-mods.xml")
    def self.create(id = nil, xml_path = nil)
      result = AtlasRb::Mash.new(JSON.parse(connection({ parent_id: id }).post(ROUTE)&.body))["community"]
      return result unless xml_path.present?

      update(result["id"], xml_path)
      find(result["id"])
    end

    # Delete a Community.
    #
    # @param id [String] the Community ID.
    # @return [Faraday::Response] the raw delete response.
    #
    # @example
    #   AtlasRb::Community.destroy("c-123")
    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    # List the immediate children (sub-Communities and Collections) of a Community.
    #
    # @param id [String] the parent Community ID.
    # @return [Hash] the child listing from `GET /communities/<id>/children`.
    #
    # @example
    #   AtlasRb::Community.children("c-123")
    def self.children(id)
      AtlasRb::Mash.new(JSON.parse(connection({}).get(ROUTE + id + '/children')&.body))
    end

    # Replace a Community's metadata by uploading a MODS XML document.
    #
    # @param id [String] the Community ID.
    # @param xml_path [String] path to a MODS XML file on disk.
    # @return [Hash] the parsed JSON response from the patch.
    #
    # @example
    #   AtlasRb::Community.update("c-123", "/tmp/community-mods.xml")
    def self.update(id, xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      AtlasRb::Mash.new(JSON.parse(multipart({}).patch(ROUTE + id, payload)&.body))
    end

    # Patch individual metadata fields without uploading a full MODS document.
    #
    # @param id [String] the Community ID.
    # @param values [Hash] field-level metadata updates (shape determined by
    #   the Atlas server, typically a mapping from MODS field name to value).
    # @return [Hash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Community.metadata("c-123", title: "New Name")
    def self.metadata(id, values)
      AtlasRb::Mash.new(JSON.parse(connection({ metadata: values }).patch(ROUTE + id)&.body))
    end

    # Fetch the Community's MODS representation in the requested format.
    #
    # @param id [String] the Community ID.
    # @param kind [String, nil] one of `"json"` (default when omitted),
    #   `"html"`, or `"xml"`. When `nil`, Atlas returns its default
    #   representation.
    # @return [String] the raw response body (JSON, HTML, or XML serialized
    #   as a string).
    #
    # @example HTML rendering for display
    #   AtlasRb::Community.mods("c-123", "html")
    def self.mods(id, kind = nil)
      # json default, html, xml
      connection({}).get(
        ROUTE + id + '/mods' + (kind.present? ? ".#{kind}" : '')
        )&.body
    end
  end
end
