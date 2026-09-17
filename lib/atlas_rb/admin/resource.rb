# frozen_string_literal: true

module AtlasRb
  module Admin
    # Destructive lifecycle operations that need no type, against Atlas's
    # generic `/resources/{id}` surface.
    #
    # The typed {AtlasRb::Admin::Work}, {AtlasRb::Admin::Collection} and
    # {AtlasRb::Admin::Community} delegate here. See {AtlasRb::Admin} for why
    # the namespace exists and what `confirm: :i_understand` is for — both
    # apply unchanged, which is why purge did not move onto
    # {AtlasRb::Resource} beside the other generic writes.
    class Resource
      extend AtlasRb::FaradayHelper

      # Atlas REST endpoint prefix.
      # @api private
      ROUTE = "/resources/"

      # Hard-delete a resource — a purge, not a withdrawal.
      #
      # Removes the resource's metadata, cascades into its members, and removes
      # the OCFL objects holding the preserved bytes: every retained revision,
      # not only the current one. Nothing survives but the audit row, which
      # records the NOIDs it removed.
      #
      # Unrecoverable — prefer {AtlasRb::Resource.tombstone} for the
      # user-visible withdrawal path, which keeps everything and can be
      # reversed. Admin-only.
      #
      # @param id [String] the resource's NOID.
      # @param confirm [Symbol] must be `:i_understand`.
      # @param nuid [String, nil] optional acting user's NUID.
      # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
      #   header.
      # @return [Faraday::Response] the raw delete response.
      # @raise [ArgumentError] if `confirm:` is missing or not the sentinel
      #   value. Raised before any request goes out.
      #
      # @example
      #   AtlasRb::Admin::Resource.destroy("xsj3xmz", confirm: :i_understand)
      def self.destroy(id, confirm:, nuid: nil, on_behalf_of: nil)
        unless confirm == :i_understand
          raise ArgumentError,
                "AtlasRb::Admin::Resource.destroy requires confirm: :i_understand"
        end
        connection({}, nuid, on_behalf_of: on_behalf_of).delete(ROUTE + id)
      end

      # Restore a previously-tombstoned resource.
      #
      # Reverses a withdrawal: search and show pages stop returning a withdrawn
      # stub. No `confirm:` marker — restoring is itself reversible, by
      # tombstoning again.
      #
      # @param id [String] the resource's NOID.
      # @param nuid [String, nil] optional acting user's NUID.
      # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
      #   header.
      # @return [Faraday::Response] the raw response.
      #
      # @example
      #   AtlasRb::Admin::Resource.restore("xsj3xmz")
      def self.restore(id, nuid: nil, on_behalf_of: nil)
        connection({}, nuid, on_behalf_of: on_behalf_of).post(ROUTE + id + '/restore')
      end
    end
  end
end
