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

    # Tombstone (withdraw) a Collection.
    #
    # The Collection remains in Atlas storage but is marked as withdrawn:
    # search and show pages return a withdrawn stub for every user. Atlas
    # rejects the request with `422 has_live_children` if the Collection
    # still has live (non-tombstoned) Works.
    #
    # @param id [String] the Collection ID.
    # @param nuid [String] the acting user's NUID, stamped on the resource
    #   as `tombstoned_by` for audit purposes.
    # @return [Faraday::Response] the raw response. `200`/`204` on success;
    #   `422` with `{"code":"has_live_children"}` if the Collection is not empty.
    #
    # @example
    #   AtlasRb::Collection.tombstone("col-456", nuid: "000000002")
    def self.tombstone(id, nuid:)
      connection({}, nuid).post(ROUTE + id + '/tombstone')
    end

    # Restore a previously tombstoned Collection.
    #
    # **Operator-only.** Restoration is intentionally not exposed in any
    # end-user UI; call this from a Rails console session (or a future
    # admin panel) when the library has decided an object should come back.
    #
    # @param id [String] the Collection ID.
    # @param nuid [String] the acting user's NUID.
    # @return [Faraday::Response] the raw response.
    #
    # @example Operator restoring from `bundle exec rails console`
    #   AtlasRb::Collection.restore("col-456", nuid: "000000002")
    def self.restore(id, nuid:)
      connection({}, nuid).post(ROUTE + id + '/restore')
    end

    # List the Works in a Collection.
    #
    # The endpoint returns just the noids; resolve each through
    # {Resource.find} (or {Work.find}) when a full payload is needed.
    #
    # @param id [String] the Collection ID.
    # @return [Array<String>] child noids from `GET /collections/<id>/children`.
    #
    # @example
    #   AtlasRb::Collection.children("col-456")
    #   # => ["w-789", "w-790"]
    def self.children(id)
      JSON.parse(connection({}).get(ROUTE + id + '/children')&.body)
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
