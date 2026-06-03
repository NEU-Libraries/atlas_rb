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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the `"collection"` object, already unwrapped from the
    #   JSON response.
    #
    # @example
    #   AtlasRb::Collection.find("col-456")
    #   # => { "id" => "col-456", "title" => "Faculty Publications", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))["collection"]
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the created Collection payload (post-update if
    #   `xml_path` was supplied).
    #
    # @example
    #   AtlasRb::Collection.create("c-123", "/tmp/collection-mods.xml")
    def self.create(id, xml_path = nil, nuid: nil, on_behalf_of: nil)
      result = AtlasRb::Mash.new(JSON.parse(
        connection({ parent_id: id }, nuid, on_behalf_of: on_behalf_of).post(ROUTE)&.body
      ))["collection"]
      return result unless xml_path.present?

      update(result["id"], xml_path, nuid: nuid, on_behalf_of: on_behalf_of)
      find(result["id"], nuid: nuid, on_behalf_of: on_behalf_of)
    end

    # Move a Collection to a different parent Community.
    #
    # Wraps `PATCH /collections/<id>/parent` with a `parent_id` of the new
    # Community. Atlas re-parents the Collection and synchronously cascades
    # the ancestry index over its Works; the structural rules (type, cycle,
    # tombstone guards) are enforced server-side and surface as a `422`.
    #
    # Mirrors {.create}'s "single parent id" shape — same kwarg threading,
    # the only difference is the verb and that the Collection already exists.
    #
    # @param id [String] the Collection ID to move.
    # @param new_parent_id [String] the destination Community ID.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"collection"` object, already unwrapped —
    #   the same shape {.find} returns, reflecting the new `a_member_of`.
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
    #   AtlasRb::Collection.reparent("col-456", "c-999")
    def self.reparent(id, new_parent_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ parent_id: new_parent_id }, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/parent')&.body
      ))["collection"]
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
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Faraday::Response] the raw response. `200`/`204` on success;
    #   `422` with `{"code":"has_live_children"}` if the Collection is not empty.
    #
    # @example
    #   AtlasRb::Collection.tombstone("col-456", nuid: "000000002")
    def self.tombstone(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).post(ROUTE + id + '/tombstone')
    end

    # List the Works in a Collection.
    #
    # The endpoint returns just the noids; resolve each through
    # {Resource.find} (or {Work.find}) when a full payload is needed.
    #
    # @param id [String] the Collection ID.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<String>] child noids from `GET /collections/<id>/children`.
    #
    # @example
    #   AtlasRb::Collection.children("col-456")
    #   # => ["w-789", "w-790"]
    def self.children(id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/children')&.body
      )
    end

    # Replace a Collection's metadata by uploading a MODS XML document.
    #
    # @param id [String] the Collection ID.
    # @param xml_path [String] path to a MODS XML file on disk.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the parsed JSON response from the patch.
    #
    # @example
    #   AtlasRb::Collection.update("col-456", "/tmp/collection-mods.xml")
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
    # writes of machine-set Delegate URIs (thumbnails) have their own
    # purpose-specific endpoint — see {.set_thumbnails}.
    #
    # @param id [String] the Collection ID.
    # @param values [Hash] field-level metadata updates.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Collection.metadata("col-456", title: "Renamed Collection")
    def self.metadata(id, values, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ metadata: values }, nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id)&.body
      ))
    end

    # Attach the three thumbnail/preview Delegate URIs to a Collection.
    #
    # Collection-level mirror of {Work.set_thumbnails}. Atlas dispatches
    # each non-blank URI to its matching Delegate role
    # (`thumbnail_image` / `thumbnail_image_2x` / `preview_image`) via
    # `DelegateUpdater`. Missing keys are left untouched.
    #
    # @param id [String] the Collection ID.
    # @param thumbnail [String, nil] IIIF URI for the ~85² thumbnail.
    # @param thumbnail_2x [String, nil] IIIF URI for the ~170² 2x thumbnail.
    # @param preview [String, nil] IIIF URI for the ~500w preview image.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @return [AtlasRb::Mash] the parsed JSON response.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    #
    # @example
    #   AtlasRb::Collection.set_thumbnails(
    #     "col-456",
    #     thumbnail:    "https://iiif.example.edu/iiif/3/c.jp2/full/!85,85/0/default.jpg",
    #     thumbnail_2x: "https://iiif.example.edu/iiif/3/c.jp2/full/!170,170/0/default.jpg",
    #     preview:      "https://iiif.example.edu/iiif/3/c.jp2/full/500,/0/default.jpg"
    #   )
    def self.set_thumbnails(id, thumbnail: nil, thumbnail_2x: nil, preview: nil, nuid: nil, on_behalf_of: nil)
      body = { thumbnail: thumbnail, thumbnail_2x: thumbnail_2x, preview: preview }.compact
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/thumbnails', JSON.dump(body))&.body
      ))
    end

    # Fetch the Collection's MODS representation in the requested format.
    #
    # @param id [String] the Collection ID.
    # @param kind [String, nil] one of `"json"` (default), `"html"`, or
    #   `"xml"`.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [String] the raw response body in the requested format.
    #
    # @example
    #   AtlasRb::Collection.mods("col-456", "xml")
    def self.mods(id, kind = nil, nuid: nil, on_behalf_of: nil)
      # json default, html, xml
      connection({}, nuid, on_behalf_of: on_behalf_of).get(
        ROUTE + id + '/mods' + (kind.present? ? ".#{kind}" : '')
        )&.body
    end
  end
end
