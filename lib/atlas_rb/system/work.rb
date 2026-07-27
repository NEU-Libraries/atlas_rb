# frozen_string_literal: true

module AtlasRb
  module System
    # Showcase publishing: link a freshly-created Work into a depositor's
    # featured showcase Collection on their behalf, without granting the
    # depositor themselves standing edit rights on that shared Collection.
    #
    # Atlas scopes this narrowly on both sides (see Atlas's `Ability`): the
    # target Collection must be `featured`, and the Work must belong to the
    # `on_behalf_of` NUID — never an arbitrary or private Work. Cerberus's
    # `WorkDeposit#create_published` ("Publish to my community") is the one
    # caller today.
    #
    # Always authenticates via {FaradayHelper#system_connection}, so there is
    # no way to issue this as a regular user.
    class Work
      extend AtlasRb::FaradayHelper

      # @param work_id [String] the Work ID to link.
      # @param collection_id [String] the (must-be-featured) showcase
      #   Collection to link the Work into.
      # @param on_behalf_of [String] the depositor NUID this write is
      #   attributed to — required (unlike the regular, human-facing
      #   {AtlasRb::Work.add_linked_member}), since a :system call with no
      #   attribution defeats the point of this path, and Atlas's Ability
      #   grant is itself conditioned on it matching the Work's depositor.
      # @return [Array<String>] the Work's full set of linked Collection
      #   noids after the add.
      # @raise [AtlasRb::StaleResourceError] optimistic-lock conflict.
      # @raise [AtlasRb::LinkedMemberError] structural rejection (HTTP 422) —
      #   non-Collection target, tombstoned work/target, already a structural
      #   member.
      # @raise [AtlasRb::ForbiddenError] Atlas refused the link (HTTP 403) —
      #   e.g. the target Collection isn't featured, or on_behalf_of doesn't
      #   own the Work.
      #
      # @example From Cerberus's publish-to-showcase deposit branch
      #   AtlasRb::System::Work.add_linked_member(work.id, showcase.id, on_behalf_of: depositor_nuid)
      def self.add_linked_member(work_id, collection_id, on_behalf_of:)
        JSON.parse(
          system_connection({ collection_id: collection_id }, on_behalf_of: on_behalf_of)
            .post("/works/#{work_id}/linked_members")&.body
        )
      end
    end
  end
end
