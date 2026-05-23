# frozen_string_literal: true

module AtlasRb
  module Admin
    # Destructive lifecycle operations on a {AtlasRb::Work}.
    #
    # See {AtlasRb::Admin} for the rationale behind the namespace and the
    # `confirm: :i_understand` friction marker.
    class Work
      extend AtlasRb::FaradayHelper

      # Atlas REST endpoint prefix.
      # @api private
      ROUTE = "/works/"

      # Hard-delete a Work.
      #
      # Removes the Work, its FileSets, and their Blobs from Atlas
      # storage. Unrecoverable — prefer {AtlasRb::Work.tombstone} for
      # the user-visible withdrawal path. This is operator-only.
      #
      # @param id [String] the Work ID.
      # @param confirm [Symbol] must be `:i_understand`. Any other value
      #   (including the kwarg being omitted) raises `ArgumentError`.
      # @param nuid [String, nil] optional acting user's NUID. Falls
      #   through to {AtlasRb.config}.default_nuid when omitted.
      # @param on_behalf_of [String, nil] optional NUID for the
      #   `On-Behalf-Of` header. Falls through to
      #   {AtlasRb.config}.default_on_behalf_of when omitted.
      # @return [Faraday::Response] the raw delete response.
      # @raise [ArgumentError] if `confirm:` is missing or not the
      #   sentinel value.
      #
      # @example
      #   AtlasRb::Admin::Work.destroy("w-789", confirm: :i_understand)
      def self.destroy(id, confirm:, nuid: nil, on_behalf_of: nil)
        unless confirm == :i_understand
          raise ArgumentError,
                "AtlasRb::Admin::Work.destroy requires confirm: :i_understand"
        end
        connection({}, nuid, on_behalf_of: on_behalf_of).delete(ROUTE + id)
      end

      # Restore a previously-tombstoned Work.
      #
      # Reverses a withdrawal: search and show pages stop returning a
      # withdrawn stub. Operator-only; typically driven from a Rails
      # console or a future admin panel after the library has decided a
      # withdrawn Work should come back.
      #
      # @param id [String] the Work ID.
      # @param nuid [String, nil] optional acting user's NUID. Falls
      #   through to {AtlasRb.config}.default_nuid when omitted.
      # @param on_behalf_of [String, nil] optional NUID for the
      #   `On-Behalf-Of` header. Falls through to
      #   {AtlasRb.config}.default_on_behalf_of when omitted.
      # @return [Faraday::Response] the raw response.
      #
      # @example
      #   AtlasRb::Admin::Work.restore("w-789")
      def self.restore(id, nuid: nil, on_behalf_of: nil)
        connection({}, nuid, on_behalf_of: on_behalf_of).post(ROUTE + id + '/restore')
      end
    end
  end
end
