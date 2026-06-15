# frozen_string_literal: true

module AtlasRb
  # A server-managed derivative asset attached to a {Work} — thumbnails,
  # previews, and other generated representations.
  #
  # Unlike a {Blob}, a Delegate is not user-uploaded binary content; it is
  # produced and addressed by Atlas itself. Each Delegate exposes a `uri`
  # pointing at the underlying bytes plus enough metadata
  # (`mime_type`, `original_filename`, `label`, `use`) for clients to
  # render or link to it without fetching the bytes first.
  #
  # Lookups accept either the resource NOID or the `valkyrie_id`: Atlas
  # redirects NOIDs to `/delegates/:valkyrie_id` and Faraday transparently
  # follows the redirect.
  #
  # See also: {Work}, {Blob}.
  class Delegate < Resource
    # Atlas REST endpoint prefix for this resource.
    # @api private
    ROUTE = "/delegates/"

    # Fetch a single Delegate by NOID or `valkyrie_id`.
    #
    # @param id [String] the Delegate's NOID or `valkyrie_id`.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] the `"delegate"` object, already unwrapped —
    #   includes `id`, `valkyrie_id`, `use`, `uri`, `mime_type`,
    #   `original_filename`, `label`, and tombstone fields.
    #
    # @example
    #   AtlasRb::Delegate.find("d-555")
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))["delegate"]
    end
  end
end
