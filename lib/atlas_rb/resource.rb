# frozen_string_literal: true

module AtlasRb
  # Abstract base for every Atlas resource type.
  #
  # Subclasses define a `ROUTE` constant (e.g. `"/communities/"`) and override
  # whichever of `find / create / destroy / update / metadata / mods` apply.
  # The {Resource} class itself ships four endpoints that are not
  # type-specific: a generic resolver, an XML preview helper, a permissions
  # lookup, and an audit-event history fetch.
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash{String => String, Hash}] hash with two keys:
    #   - `"klass"` — the resource type, capitalized (e.g. `"Work"`).
    #   - `"resource"` — the resource payload as a Hash.
    #
    # @example Polymorphic lookup
    #   AtlasRb::Resource.find("abc123")
    #   # => { "klass" => "Work", "resource" => { "id" => "abc123", "title" => "..." } }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      result = JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get('/resources/' + id)&.body
      )
      AtlasRb::Mash.new("klass" => result.first[0].capitalize,
                        "resource" => result.first[1])
    end

    # Resolve many resources by NOID in a single round-trip.
    #
    # Wraps Atlas's `POST /resources/find_many`, which returns one lightweight
    # digest per resolvable resource — `{ "id", "noid", "klass", "title",
    # "thumbnail", "tombstoned" }` — rather than full typed payloads. Use it
    # anywhere a set of ids would otherwise be resolved with a `find`-per-id
    # fan-out (breadcrumb chains, linked-member lists, load-destination
    # pickers): one HTTP call instead of N.
    #
    # The ids travel in the request **body**, so the list is not bounded by
    # URL length. The result is **unordered** and **may be shorter than the
    # input** — unresolvable ids are dropped silently, and tombstoned
    # resources come back flagged (`"tombstoned" => true`) rather than
    # omitted. Index the result by `"noid"`; do not assume positional
    # correspondence with `ids`.
    #
    # @param ids [Array<String>] resource NOIDs to resolve. (Raw Valkyrie ids
    #   are not a supported input — the endpoint resolves alternate ids only.)
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Array<AtlasRb::Mash>] one digest Mash per resolved resource
    #   (dot- or string-keyed access); empty when nothing resolved.
    #
    # @example Resolve a set of collection titles in one call
    #   nodes  = AtlasRb::Resource.find_many(["col-456", "col-457", "missing"])
    #   by_noid = nodes.index_by { |n| n["noid"] }
    #   by_noid["col-456"].title   # => "Some Collection"
    def self.find_many(ids, nuid: nil, on_behalf_of: nil)
      JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .post('/resources/find_many', JSON.dump(ids: Array(ids)))&.body
      ).map { |node| AtlasRb::Mash.new(node) }
    end

    # Validate a MODS XML document against Atlas's schema *without* persisting it.
    #
    # Useful for surfacing validation errors in UIs before the user commits.
    #
    # @param xml_path [String] path to a MODS XML file on disk.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [String] the raw response body from `POST /resources/preview`
    #   — typically a JSON or XML error report.
    #
    # @example
    #   AtlasRb::Resource.preview("/tmp/draft-mods.xml")
    def self.preview(xml_path, nuid: nil, on_behalf_of: nil)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      multipart(nuid, on_behalf_of: on_behalf_of).post('/resources/preview', payload)&.body
    end

    # Fetch the access-control entries for a resource.
    #
    # @param id [String] an Atlas resource ID.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the `"resource"` payload from `GET /resources/<id>/permissions`,
    #   typically containing read/write/admin grant lists.
    #
    # @example
    #   AtlasRb::Resource.permissions("abc123")
    #   # => { "id" => "abc123", "read" => [...], "write" => [...] }
    def self.permissions(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .get('/resources/' + id + '/permissions')&.body
      ))["resource"]
    end

    # Fetch the audit-event history for a resource.
    #
    # Wraps Atlas's `GET /resources/<id>/history` endpoint, which returns the
    # full envelope (`resource_id` + reverse-chronological `events` array).
    # The whole envelope is preserved so callers can confirm the events
    # belong to the requested resource; access events as `result["events"]`.
    #
    # Authorization errors (`401` / `403`) are intentionally **not** caught
    # here — they surface as raw Faraday responses for the calling
    # application's rescue layer to translate.
    #
    # @todo Add pagination support once Atlas's history endpoint exposes
    #   page / per_page query params. Today the endpoint returns the full
    #   history in one shot.
    #
    # @param id [String] an Atlas resource ID.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] the parsed envelope from
    #   `GET /resources/<id>/history`, with `"resource_id"` and an `"events"`
    #   array (reverse chronological; possibly empty).
    #
    # @example
    #   result = AtlasRb::Resource.history("abc12345")
    #   result["resource_id"]            # => "abc12345"
    #   result["events"].first["action"] # => "create"
    def self.history(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .get('/resources/' + id + '/history')&.body
      ))
    end
  end
end
