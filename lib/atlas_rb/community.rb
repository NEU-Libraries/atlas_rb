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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the `"community"` object from the JSON response,
    #   already unwrapped.
    #
    # @example
    #   AtlasRb::Community.find("c-123")
    #   # => { "id" => "c-123", "title" => "College of Engineering", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))["community"]
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the created Community payload (post-update if `xml_path`
    #   was supplied).
    #
    # @example Top-level community, no metadata
    #   AtlasRb::Community.create(nil)
    #
    # @example Sub-community seeded from MODS
    #   AtlasRb::Community.create("c-parent", "/tmp/dept-mods.xml")
    def self.create(id = nil, xml_path = nil, nuid: nil, on_behalf_of: nil)
      result = AtlasRb::Mash.new(JSON.parse(
        connection({ parent_id: id }, nuid, on_behalf_of: on_behalf_of).post(ROUTE)&.body
      ))["community"]
      return result unless xml_path.present?

      update(result["id"], xml_path, nuid: nuid, on_behalf_of: on_behalf_of)
      find(result["id"], nuid: nuid, on_behalf_of: on_behalf_of)
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
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Faraday::Response] the raw response. `200`/`204` on success;
    #   `422` with `{"code":"has_live_children"}` if the Community is not empty.
    #
    # @example
    #   AtlasRb::Community.tombstone("c-123", nuid: "000000002")
    def self.tombstone(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).post(ROUTE + id + '/tombstone')
    end

    # List the immediate children (sub-Communities and Collections) of a Community.
    #
    # The endpoint returns just the noids; resolve each through
    # {Resource.find} (which dispatches by type) when richer payloads are
    # needed.
    #
    # @param id [String] the parent Community ID.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<String>] child noids from `GET /communities/<id>/children`.
    #
    # @example
    #   AtlasRb::Community.children("c-123")
    #   # => ["fn106x926", "kw52j804p"]
    def self.children(id, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/children')&.body
      )
    end

    # Replace a Community's metadata by uploading a MODS XML document.
    #
    # @param id [String] the Community ID.
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
    #   AtlasRb::Community.update("c-123", "/tmp/community-mods.xml")
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
    # @param id [String] the Community ID.
    # @param values [Hash] field-level metadata updates (shape determined by
    #   the Atlas server, typically a mapping from MODS field name to value).
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Community.metadata("c-123", title: "New Name")
    def self.metadata(id, values, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ metadata: values }, nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id)&.body
      ))
    end

    # Attach the three thumbnail/preview Delegate URIs to a Community.
    #
    # Community-level mirror of {Work.set_thumbnails}. Atlas dispatches
    # each non-blank URI to its matching Delegate role
    # (`thumbnail_image` / `thumbnail_image_2x` / `preview_image`) via
    # `DelegateUpdater`. Missing keys are left untouched.
    #
    # @param id [String] the Community ID.
    # @param thumbnail [String, nil] IIIF URI for the ~85² thumbnail.
    # @param thumbnail_2x [String, nil] IIIF URI for the ~170² 2x thumbnail.
    # @param preview [String, nil] IIIF URI for the ~500w preview image.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @return [AtlasRb::Mash] the parsed JSON response.
    #
    # @example
    #   AtlasRb::Community.set_thumbnails(
    #     "c-123",
    #     thumbnail:    "https://iiif.example.edu/iiif/3/m.jp2/full/!85,85/0/default.jpg",
    #     thumbnail_2x: "https://iiif.example.edu/iiif/3/m.jp2/full/!170,170/0/default.jpg",
    #     preview:      "https://iiif.example.edu/iiif/3/m.jp2/full/500,/0/default.jpg"
    #   )
    def self.set_thumbnails(id, thumbnail: nil, thumbnail_2x: nil, preview: nil, nuid: nil, on_behalf_of: nil)
      body = { thumbnail: thumbnail, thumbnail_2x: thumbnail_2x, preview: preview }.compact
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/thumbnails', JSON.dump(body))&.body
      ))
    end

    # Fetch the Community's MODS representation in the requested format.
    #
    # @param id [String] the Community ID.
    # @param kind [String, nil] one of `"json"` (default when omitted),
    #   `"html"`, or `"xml"`. When `nil`, Atlas returns its default
    #   representation.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [String] the raw response body (JSON, HTML, or XML serialized
    #   as a string).
    #
    # @example HTML rendering for display
    #   AtlasRb::Community.mods("c-123", "html")
    def self.mods(id, kind = nil, nuid: nil, on_behalf_of: nil)
      # json default, html, xml
      connection({}, nuid, on_behalf_of: on_behalf_of).get(
        ROUTE + id + '/mods' + (kind.present? ? ".#{kind}" : '')
        )&.body
    end
  end
end
