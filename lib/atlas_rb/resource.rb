# frozen_string_literal: true

module AtlasRb
  # Abstract base for every Atlas resource type.
  #
  # Subclasses define a `ROUTE` constant (e.g. `"/communities/"`) and override
  # whichever of `find / create / destroy / update / metadata / mods` apply.
  # The {Resource} class itself ships three endpoints that are not
  # type-specific: a generic resolver, an XML preview helper, and a
  # permissions lookup.
  #
  # The Atlas resource hierarchy is:
  #
  #     {Community}  →  {Collection}  →  {Work}  →  {FileSet}  →  {Blob}
  #
  # Subclasses extend {FaradayHelper} so that `connection(...)` and
  # `multipart(...)` are available as class methods.
  class Resource
    extend AtlasRb::FaradayHelper

    # Resolve any Atlas resource by ID without knowing its type up front.
    #
    # The Atlas server returns a single-key JSON object whose key names the
    # resource type (`"community"`, `"collection"`, `"work"`, etc.); this
    # method splits that into a normalized `{ "klass" => ..., "resource" => ... }`
    # pair so callers can dispatch on type.
    #
    # @param id [String] an Atlas resource ID of any type.
    # @return [Hash{String => String, Hash}] hash with two keys:
    #   - `"klass"` — the resource type, capitalized (e.g. `"Work"`).
    #   - `"resource"` — the resource payload as a Hash.
    #
    # @example Polymorphic lookup
    #   AtlasRb::Resource.find("abc123")
    #   # => { "klass" => "Work", "resource" => { "id" => "abc123", "title" => "..." } }
    def self.find(id)
      result = JSON.parse(connection({}).get('/resources/' + id)&.body)
      { "klass" => result.first[0].capitalize,
        "resource" => result.first[1] }
    end

    # Validate a MODS XML document against Atlas's schema *without* persisting it.
    #
    # Useful for surfacing validation errors in UIs before the user commits.
    #
    # @param xml_path [String] path to a MODS XML file on disk.
    # @return [String] the raw response body from `POST /resources/preview`
    #   — typically a JSON or XML error report.
    #
    # @example
    #   AtlasRb::Resource.preview("/tmp/draft-mods.xml")
    def self.preview(xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      multipart({}).post('/resources/preview', payload)&.body
    end

    # Fetch the access-control entries for a resource.
    #
    # @param id [String] an Atlas resource ID.
    # @return [Hash] the `"resource"` payload from `GET /resources/<id>/permissions`,
    #   typically containing read/write/admin grant lists.
    #
    # @example
    #   AtlasRb::Resource.permissions("abc123")
    #   # => { "id" => "abc123", "read" => [...], "write" => [...] }
    def self.permissions(id)
      result = JSON.parse(connection({}).get('/resources/' + id + '/permissions')&.body)["resource"]
    end
  end
end
