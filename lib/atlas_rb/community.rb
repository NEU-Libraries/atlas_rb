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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash, nil] the `"community"` object from the JSON response,
    #   already unwrapped, or `nil` when the Community does not exist (`404`).
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` (e.g. an
    #   auth/validation error envelope), carrying Atlas's status + body.
    #
    # @example
    #   AtlasRb::Community.find("c-123")
    #   # => { "id" => "c-123", "title" => "College of Engineering", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      body = fetch_resource(ROUTE + id, nuid: nuid, on_behalf_of: on_behalf_of)
      body && AtlasRb::Mash.new(body)["community"]
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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

    # Move a Community to a different parent Community — or to the top of the
    # tree.
    #
    # Wraps `PATCH /communities/<id>/parent` with a `parent_id` of the new
    # parent Community. Pass `new_parent_id = nil` to promote the Community to
    # a top-level node (no parent) — mirroring how {.create} treats a `nil`
    # `id`; the gem omits the blank param and Atlas reads it as "move to top".
    # Atlas re-parents the Community and synchronously cascades the ancestry
    # index over its descendant Collections and Works; the structural rules
    # (cycle, tombstone guards) are enforced server-side and surface as a
    # `422`.
    #
    # @param id [String] the Community ID to move.
    # @param new_parent_id [String, nil] the destination Community ID, or
    #   `nil` to move the Community to the top of the tree.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"community"` object, already unwrapped —
    #   the same shape {.find} returns, reflecting the new `a_member_of`.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
    # @raise [AtlasRb::ReparentError] if Atlas rejects the move on structural
    #   grounds (HTTP 422 — `cycle`, `tombstoned_node`, `tombstoned_parent`,
    #   `parent_not_found`). The envelope's `error` code is exposed as `#code`.
    # @raise [AtlasRb::ForbiddenError] if Atlas refuses the move on
    #   authorization grounds (HTTP 403).
    #
    # @example Move under another Community
    #   AtlasRb::Community.reparent("c-123", "c-999")
    #
    # @example Promote to a top-level Community
    #   AtlasRb::Community.reparent("c-123", nil)
    def self.reparent(id, new_parent_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ parent_id: new_parent_id }, nuid, on_behalf_of: on_behalf_of)
          .patch(ROUTE + id + '/parent')&.body
      ))["community"]
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @return [AtlasRb::Mash] the parsed JSON response.
    # @raise [AtlasRb::StaleResourceError] if Atlas reports an optimistic-lock
    #   conflict that exhausted its internal retry budget (HTTP 409 with
    #   `error: "stale_resource"`).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
