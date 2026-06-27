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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash{String => String, Hash}, nil] hash with two keys, or `nil`
    #   when the id resolves to nothing (`404`):
    #   - `"klass"` — the resource type, capitalized (e.g. `"Work"`).
    #   - `"resource"` — the resource payload as a Hash.
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` (e.g. an
    #   auth/validation error envelope), carrying Atlas's status + body.
    #
    # @example Polymorphic lookup
    #   AtlasRb::Resource.find("abc123")
    #   # => { "klass" => "Work", "resource" => { "id" => "abc123", "title" => "..." } }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      result = fetch_resource('/resources/' + id, nuid: nuid, on_behalf_of: on_behalf_of)
      return nil if result.nil?

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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
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

    # List the retained MODS versions for a resource.
    #
    # Wraps Atlas's `GET /resources/<id>/mods/versions`, which returns the
    # full envelope — `resource_id` plus a reverse-chronological `versions`
    # array — as an `AtlasRb::Mash`. Each version descriptor mirrors the
    # audit-event shape (`version_id`, `created`, `actor_nuid`,
    # `on_behalf_of_nuid`, `source`, `note`) so the two streams render with
    # the same helpers; actor fields are correlated from the audit log and
    # may be `null` when a version has no matching edit event.
    #
    # Type-agnostic: pass any Modsable resource ID (Community, Collection,
    # Work). A resource with no MODS comes back as `{ "versions" => [] }`.
    #
    # Version labels are opaque, sortable OCFL `vN` strings — not a 1-based
    # counter — so treat them as identifiers to feed back into
    # {mods_version}, not as ordinals. The server admin-gates this endpoint
    # (it exposes edit attribution); `401` / `403` surface as raw Faraday
    # responses, matching {history}.
    #
    # @param id [String] an Atlas resource ID.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] the parsed envelope, with `"resource_id"` and a
    #   `"versions"` array (reverse chronological; possibly empty).
    #
    # @example
    #   history = AtlasRb::Resource.mods_versions("w-789")
    #   history["versions"].first["version_id"] # => "v5"
    #   history["versions"].first["actor_nuid"]  # => "000000002"
    def self.mods_versions(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .get('/resources/' + id + '/mods/versions')&.body
      ))
    end

    # Fetch the MODS document as of a specific version.
    #
    # Wraps Atlas's `GET /resources/<id>/mods/versions/<version_id>` and
    # returns the **raw response body** (not parsed) — mirroring
    # {Work.mods}. Pass a `version_id` obtained from {mods_versions} (an
    # opaque OCFL `vN` label).
    #
    # Only XML is version-recoverable: the JSON access copy is overwritten in
    # place, so the server serves historical XML (the default). `kind:` is
    # accepted for parity with {Work.mods} but XML is currently the only
    # supported format. An unknown version yields a `404` (raw Faraday
    # response).
    #
    # @param id [String] an Atlas resource ID.
    # @param version_id [String] an OCFL version label from {mods_versions},
    #   e.g. `"v3"`.
    # @param kind [String, nil] response format extension. Omit (or pass
    #   `"xml"`) for the historical XML — the only format the server retains.
    # @param nuid [String, nil] optional acting user's NUID. On the relay-signing
    #   path it is signed into the assertion `sub`; on the BYO-JWT (`ATLAS_JWT`)
    #   path it is ignored (identity lives in the token).
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [String] the raw MODS XML body for that version.
    #
    # @example Diff two MODS versions
    #   old_xml = AtlasRb::Resource.mods_version("w-789", "v3")
    #   new_xml = AtlasRb::Resource.mods_version("w-789", "v5")
    def self.mods_version(id, version_id, kind: nil, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).get(
        '/resources/' + id + '/mods/versions/' + version_id +
          (kind.present? ? ".#{kind}" : '')
      )&.body
    end

    # Shared read path behind every typed `find`: perform a single-resource
    # `GET` and return the parsed JSON envelope, or `nil` when Atlas reports
    # the resource is absent (`404`).
    #
    # Its job is to stop `find` from silently coercing an error *envelope*
    # into `nil`. Atlas renders auth/validation failures as a JSON body
    # (`{ "error" => ... }`, status 400/401/403/422); a naive
    # `JSON.parse(body)["work"]` returns `nil` for the missing `"work"` key —
    # losing the status and message, and surfacing as a baffling
    # `NoMethodError` far from the cause. Mapping:
    #
    # - `404`             → `nil` (clean "not found"; also avoids the
    #   `JSON::ParserError` the old code raised on the empty `head :not_found`
    #   body).
    # - any other non-2xx → {AtlasRb::ResourceError} carrying Atlas's status +
    #   body, so the failure is attributable at the boundary.
    # - `2xx`             → the parsed JSON Hash, for the caller to unwrap.
    #
    # @param path [String] the resource path to GET (e.g. `"/works/abc123"`).
    # @param nuid [String, nil] optional acting user's NUID (see {find}).
    # @param on_behalf_of [String, nil] optional `On-Behalf-Of` NUID (see {find}).
    # @return [Hash, nil] the parsed JSON envelope, or `nil` on `404`.
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404`.
    # @api private
    def self.fetch_resource(path, nuid: nil, on_behalf_of: nil)
      resp = connection({}, nuid, on_behalf_of: on_behalf_of).get(path)
      return nil if resp.status == 404
      unless resp.success?
        raise AtlasRb::ResourceError.new("GET #{path} → #{resp.status}: #{resp.body}", response: resp)
      end

      JSON.parse(resp.body)
    end
    private_class_method :fetch_resource
  end
end
