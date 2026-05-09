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

    # Tombstone (withdraw) a Community.
    #
    # The Community remains in Atlas storage but is marked as withdrawn:
    # search and show pages return a withdrawn stub for every user. Atlas
    # rejects the request with `422 has_live_children` if the Community
    # still has live (non-tombstoned) members.
    #
    # @param id [String] the Community ID.
    # @param nuid [String] the acting user's NUID, stamped on the resource
    #   as `tombstoned_by` for audit purposes.
    # @return [Faraday::Response] the raw response. `200`/`204` on success;
    #   `422` with `{"code":"has_live_children"}` if the Community is not empty.
    #
    # @example
    #   AtlasRb::Community.tombstone("c-123", nuid: "000000002")
    def self.tombstone(id, nuid:)
      connection({}, nuid).post(ROUTE + id + '/tombstone')
    end

    # Restore a previously tombstoned Community.
    #
    # **Operator-only.** Restoration is intentionally not exposed in any
    # end-user UI; call this from a Rails console session (or a future
    # admin panel) when the library has decided an object should come back.
    #
    # @param id [String] the Community ID.
    # @param nuid [String] the acting user's NUID.
    # @return [Faraday::Response] the raw response.
    #
    # @example Operator restoring from `bundle exec rails console`
    #   AtlasRb::Community.restore("c-123", nuid: "000000002")
    def self.restore(id, nuid:)
      connection({}, nuid).post(ROUTE + id + '/restore')
    end

    # List the immediate children (sub-Communities and Collections) of a Community.
    #
    # The endpoint returns just the noids; resolve each through
    # {Resource.find} (which dispatches by type) when richer payloads are
    # needed.
    #
    # @param id [String] the parent Community ID.
    # @return [Array<String>] child noids from `GET /communities/<id>/children`.
    #
    # @example
    #   AtlasRb::Community.children("c-123")
    #   # => ["fn106x926", "kw52j804p"]
    def self.children(id)
      JSON.parse(connection({}).get(ROUTE + id + '/children')&.body)
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
