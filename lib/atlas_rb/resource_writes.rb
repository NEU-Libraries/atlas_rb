# frozen_string_literal: true

module AtlasRb
  # Reopens {Resource} with the writes that need no type. Atlas serves each one
  # as a verb on the `/resources/{id}` sub-resource that already serves its
  # `GET`, so a caller holding only a NOID never resolves the type first.
  #
  # Loaded after the subclasses because the typed writes delegate here, and
  # because {Resource::TYPE_MAP} in `resource_types.rb` has the same ordering
  # requirement.
  #
  # **The names are deliberately not `update` and `metadata`.** Neither typed
  # name says which document it writes, and `Resource.mods` / `.permissions`
  # are already taken by the reads — overloading them by arity would give one
  # name two behaviours on the ACL surface.
  #
  # Atlas refuses a type that cannot take the write; the gem does not
  # pre-check. A MODS write aimed at a FileSet answers `404`, the same as the
  # `GET` on that path.
  #
  # **There are no typed counterparts.** One URL serves every type, so a typed
  # write would name a type it could not enforce. The subclasses still *answer*
  # these methods, because they inherit them — `AtlasRb::Work.tombstone(id)` is
  # the same call as `AtlasRb::Resource.tombstone(id)`, and neither checks that
  # `id` names a Work. That has always been true of the generic reads too;
  # {Resource.find} is the call that reports a type.
  class Resource
    # Replace a resource's MODS document.
    #
    # `PUT`, not `PATCH`: the caller assembles the whole document. Descriptive
    # merge logic lives in the client, so a partial document replaces rather
    # than merges, and the verb says so.
    #
    # @param id [String] the resource's NOID.
    # @param xml_path [String] path to the MODS XML to upload.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @param origin [String, nil] the editing surface to record on the audit
    #   event, e.g. `"xml_editor"`. Omitted from the body when nil.
    # @return [AtlasRb::Mash] the resource, unwrapped from its type key.
    # @raise [AtlasRb::NotFoundError] on `404` — no such id, or a type that
    #   holds no MODS. The write did not happen either way.
    # @raise [AtlasRb::StaleResourceError] on an optimistic-lock conflict.
    # @raise [AtlasRb::ResourceError] on any other non-2xx.
    #
    # @example
    #   AtlasRb::Resource.put_mods("xsj3xmz", "/tmp/work.xml", origin: "xml_editor")
    def self.put_mods(id, xml_path, nuid: nil, on_behalf_of: nil, origin: nil)
      unwrap(write_resource(
               multipart(nuid, on_behalf_of: on_behalf_of)
                 .put('/resources/' + id + '/mods', mods_upload_payload(xml_path, origin))
             ))
    end

    # Adjust a resource's ACL.
    #
    # `PATCH`, and every key merges: a key you omit keeps its stored value.
    # Pass an explicit empty array to clear one. So changing a single slot no
    # longer needs the read-the-whole-envelope-and-write-it-back round trip.
    #
    # @param id [String] the resource's NOID.
    # @param values [Hash] the ACL keys to change — any of `embargo`,
    #   `depositor`, `proxy_uploader`, `edit_users`, `read`, `edit`.
    # @param nuid [String, nil] optional acting user's NUID.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header.
    # @return [AtlasRb::Mash] the resource, unwrapped from its type key.
    # @raise [AtlasRb::NotFoundError] on `404` — the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, including the `403`
    #   Atlas answers when a caller tries to remove a grant for a group it does
    #   not belong to.
    #
    # @example Publish, leaving every other key alone
    #   AtlasRb::Resource.set_permissions("xsj3xmz", { "read" => ["public"] })
    def self.set_permissions(id, values, nuid: nil, on_behalf_of: nil)
      unwrap(write_resource(
               connection({ permissions: values }, nuid, on_behalf_of: on_behalf_of)
                 .patch('/resources/' + id + '/permissions')
             ))
    end

    # Attach the three thumbnail-family IIIF Delegate URIs to a resource.
    #
    # Only the URIs you pass are upserted; an omitted key is left untouched.
    #
    # @param id [String] the resource's NOID.
    # @param thumbnail [String, nil] IIIF URI for the ~85² thumbnail.
    # @param thumbnail_2x [String, nil] IIIF URI for the ~170² 2x thumbnail.
    # @param preview [String, nil] IIIF URI for the ~500w preview image.
    # @param nuid [String, nil] optional acting user's NUID.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header.
    # @return [AtlasRb::Mash] the resource, unwrapped from its type key.
    # @raise [AtlasRb::NotFoundError] on `404` — the write did not happen.
    # @raise [AtlasRb::StaleResourceError] on an optimistic-lock conflict.
    # @raise [AtlasRb::ResourceError] on any other non-2xx.
    def self.set_thumbnails(id, thumbnail: nil, thumbnail_2x: nil, preview: nil, nuid: nil, on_behalf_of: nil)
      body = { thumbnail: thumbnail, thumbnail_2x: thumbnail_2x, preview: preview }.compact
      unwrap(write_resource(
               connection({}, nuid, on_behalf_of: on_behalf_of)
                 .patch('/resources/' + id + '/thumbnails', JSON.dump(body))
             ))
    end

    # Move a resource under a different parent.
    #
    # Authorization is two-sided — the caller needs the right on the moved node
    # **and** on the destination. Omit `new_parent_id` to move a Community to
    # the top of the tree.
    #
    # @param id [String] the NOID of the resource to move.
    # @param new_parent_id [String, nil] the destination's NOID.
    # @param nuid [String, nil] optional acting user's NUID.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header.
    # @return [AtlasRb::Mash] the resource, unwrapped from its type key.
    # @raise [AtlasRb::NotFoundError] on `404` — the write did not happen.
    # @raise [AtlasRb::ResourceError] on any other non-2xx, including the `422`
    #   Atlas answers for an unresolvable destination or a containment refusal.
    def self.reparent(id, new_parent_id = nil, nuid: nil, on_behalf_of: nil)
      unwrap(write_resource(
               connection({ parent_id: new_parent_id }, nuid, on_behalf_of: on_behalf_of)
                 .patch('/resources/' + id + '/parent')
             ))
    end

    # Restore is the operator's counterpart and lives in
    # {AtlasRb::Admin::Resource}, where the namespace is the marker.
    #
    # Tombstone (withdraw) a resource.
    #
    # Returns the **raw response** rather than raising, because Atlas refuses a
    # container that still holds live children with a `422` carrying
    # `has_live_children` — a legitimate answer the caller has to read, not an
    # error. Reversible via {.restore}.
    #
    # @param id [String] the resource's NOID.
    # @param nuid [String, nil] the acting user's NUID, stamped on the resource
    #   as `tombstoned_by`.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header.
    # @return [Faraday::Response] the raw response — read `status` yourself.
    def self.tombstone(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).post('/resources/' + id + '/tombstone')
    end

    # Atlas answers a write with the resource under its type key, matching what
    # `GET /{type}/{id}` returns. The caller of a type-agnostic write does not
    # know that key, so it is unwrapped here rather than left for them to
    # guess -- {Resource.find} is the call that reports a type.
    def self.unwrap(body)
      AtlasRb::Mash.new(body).values.first
    end
    private_class_method :unwrap
  end
end
