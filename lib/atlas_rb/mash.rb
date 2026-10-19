# frozen_string_literal: true

require "hashie"

module AtlasRb
  # Shared `Hashie::Mash` subclass used to wrap parsed JSON responses so
  # callers can use dot access (`work.id`) alongside string-keyed access
  # (`work["id"]`).
  #
  # `disable_warnings` silences Hashie's stderr noise when an Atlas
  # response key collides with an existing `Hash` method (e.g. `class`,
  # `type`, `id`).
  class Mash < Hashie::Mash
    disable_warnings

    # The AtlasRb class named by this row's `"klass"`.
    #
    # Every Atlas payload that names a type carries it as `"klass"`, in the
    # class-name spelling: {Resource.find}, {Resource.find_many}, `ancestors`
    # nodes, and the Solr digests from {Resource.search},
    # {Resource.descendant_works} and {Compilation.contents}. Nested hashes
    # are Mashes too, so an `ancestors` node answers this as well.
    #
    # @return [Class] the AtlasRb resource class.
    # @raise [ArgumentError] when the row has no `"klass"`, or names a type
    #   this gem does not register.
    # @example Load a search hit as its full resource
    #   hit = AtlasRb::Resource.search("whaling").results.first
    #   hit.resource_class.find(hit.noid)
    def resource_class
      Resource.resolve_type(self["klass"])
    end
  end
end
