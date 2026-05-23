# frozen_string_literal: true

module AtlasRb
  module Admin
    # Destructive lifecycle operations on a {AtlasRb::Community}.
    #
    # See {AtlasRb::Admin} for the rationale behind the namespace and the
    # `confirm: :i_understand` friction marker.
    class Community
      extend AtlasRb::FaradayHelper

      # Atlas REST endpoint prefix.
      # @api private
      ROUTE = "/communities/"

      # Hard-delete a Community.
      #
      # Unrecoverable — prefer {AtlasRb::Community.tombstone} for
      # user-visible withdrawal. Operator-only.
      #
      # @param id [String] the Community ID.
      # @param confirm [Symbol] must be `:i_understand`. Any other value
      #   raises `ArgumentError`.
      # @param nuid [String, nil] optional acting user's NUID.
      # @param on_behalf_of [String, nil] optional `On-Behalf-Of` NUID.
      # @return [Faraday::Response] the raw delete response.
      # @raise [ArgumentError] if `confirm:` is missing or not the
      #   sentinel value.
      #
      # @example
      #   AtlasRb::Admin::Community.destroy("c-123", confirm: :i_understand)
      def self.destroy(id, confirm:, nuid: nil, on_behalf_of: nil)
        unless confirm == :i_understand
          raise ArgumentError,
                "AtlasRb::Admin::Community.destroy requires confirm: :i_understand"
        end
        connection({}, nuid, on_behalf_of: on_behalf_of).delete(ROUTE + id)
      end

      # Restore a previously-tombstoned Community.
      #
      # @param id [String] the Community ID.
      # @param nuid [String, nil] optional acting user's NUID.
      # @param on_behalf_of [String, nil] optional `On-Behalf-Of` NUID.
      # @return [Faraday::Response] the raw response.
      #
      # @example
      #   AtlasRb::Admin::Community.restore("c-123")
      def self.restore(id, nuid: nil, on_behalf_of: nil)
        connection({}, nuid, on_behalf_of: on_behalf_of).post(ROUTE + id + '/restore')
      end
    end
  end
end
