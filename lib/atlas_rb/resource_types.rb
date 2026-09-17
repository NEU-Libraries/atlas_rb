# frozen_string_literal: true

module AtlasRb
  # Reopens {Resource} with the resource-type vocabulary. This lives in its own
  # file, required after the eight subclasses, because the map holds the classes
  # themselves and every one of them subclasses {Resource} — so none of them is
  # defined yet while `resource.rb` is loading.
  class Resource
    # Every type the Atlas resolver can answer with, keyed by each spelling the
    # DRS stack produces for it: Atlas's wire key (`"file_set"`), the Ruby class
    # name Solr indexes as `internal_resource` (`"FileSet"`), and the
    # capitalize-of-the-wire-key form (`"File_set"`) that a caller can still be
    # holding from a value this gem emitted before {Resource.class_for} existed.
    # A caller cannot tell which of the three it holds, so all three resolve.
    #
    # Stated rather than derived: {Blob}'s `ROUTE` is `/files/`, so nothing in
    # the routes turns a type into its class either.
    TYPE_MAP = {
      "work" => Work, "Work" => Work,
      "collection" => Collection, "Collection" => Collection,
      "community" => Community, "Community" => Community,
      "compilation" => Compilation, "Compilation" => Compilation,
      "file_set" => FileSet, "FileSet" => FileSet, "File_set" => FileSet,
      "blob" => Blob, "Blob" => Blob,
      "delegate" => Delegate, "Delegate" => Delegate,
      "person" => Person, "Person" => Person
    }.freeze

    # Resolve a resource-type string to the class that models it.
    #
    # Use this on any type that arrives as runtime data — {Resource.find}'s
    # `"klass"`, a Solr `internal_resource` value, or Atlas's wire key — rather
    # than reaching into this namespace with `const_get`. The set is closed and
    # stated in {TYPE_MAP}; it is not a naming rule.
    #
    # An unrecognized type raises instead of resolving to `nil` or to whatever
    # constant happens to bear that name. A caller holding a type this gem does
    # not define has to hear about it here, where the cause is, rather than at
    # the `NoMethodError` a few frames later.
    #
    # @param name [String, Symbol] a resource type in any of the three
    #   spellings {TYPE_MAP} accepts.
    # @return [Class] the AtlasRb class for that type.
    # @raise [ArgumentError] when the gem defines no class for that type.
    #
    # @example Dispatching on a type that arrives as data
    #   found = AtlasRb::Resource.find("b8gtjvk")
    #   AtlasRb::Resource.class_for(found["klass"]).find(found["resource"]["id"])
    #
    # @example Every spelling of one type
    #   AtlasRb::Resource.class_for("file_set") # => AtlasRb::FileSet
    #   AtlasRb::Resource.class_for("FileSet")  # => AtlasRb::FileSet
    #   AtlasRb::Resource.class_for("File_set") # => AtlasRb::FileSet
    def self.class_for(name)
      TYPE_MAP.fetch(name.to_s) do
        raise ArgumentError, "unknown Atlas resource type: #{name.inspect}"
      end
    end
  end
end
