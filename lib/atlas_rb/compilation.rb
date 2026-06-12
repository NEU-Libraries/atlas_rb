# frozen_string_literal: true

module AtlasRb
  # A Compilation (DRS "Set") — a personal, curated, recipe-based grouping
  # of {Work}s and {Collection}s.
  #
  # The recipe is three noid lists: included collections (resolved
  # transitively — the collection plus everything beneath it), individually
  # included works, and excluded works ("set-asides", subtracted from the
  # resolved union). Atlas resolves the recipe at read time via
  # {.contents}; nothing is materialized.
  #
  # Compilations are Atlas-side ActiveRecord (ephemeral curation, not
  # repository content), but carry a minted NOID as their public id — so
  # ids here look exactly like every other resource's. There is no `/mods`,
  # thumbnail, or tombstone surface to bind. Membership rules (Works and
  # Collections only, no Communities) are enforced server-side; a rejected
  # add surfaces as {AtlasRb::CompilationError} (422), an authorization
  # refusal as {AtlasRb::ForbiddenError} (403).
  #
  # See also: {Work.add_linked_member} — the membership add/remove pairs
  # here mirror that precedent.
  class Compilation < Resource
    # Atlas REST endpoint prefix for this resource.
    # @api private
    ROUTE = "/compilations/"

    # Fetch a single Compilation by ID.
    #
    # Visibility is per-row: the owner, holders of an explicit read/edit
    # grant, and (for public Sets) anyone — a private Set read by a
    # non-grantee raises {AtlasRb::ForbiddenError}.
    #
    # @param id [String] the Compilation ID (NOID).
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the `"compilation"` object, already unwrapped — `id`,
    #   `title`, `description`, `depositor`, the three recipe arrays
    #   (`included_collections`, `included_works`, `excluded_works`), the
    #   ACL arrays, and timestamps.
    # @raise [AtlasRb::ForbiddenError] if the caller may not read this Set.
    #
    # @example
    #   AtlasRb::Compilation.find("c-123", nuid: "000000002")
    #   # => { "id" => "c-123", "title" => "Course readings", ... }
    def self.find(id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id)&.body
      ))["compilation"]
    end

    # List Compilations, owner-scoped and paginated (newest first).
    #
    # Defaults to the acting user's own Sets. Pass `owner:` to list another
    # user's — that is admin-only and raises {AtlasRb::ForbiddenError} for
    # anyone else. There is no public browse surface.
    #
    # @param owner [String, nil] NUID whose Sets to list (admin-only when it
    #   isn't the acting user). Omit for "my Sets".
    # @param page [Integer, nil] 1-indexed page number.
    # @param per_page [Integer, nil] page size override.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] `{ "compilations" => [...], "pagination" => {...} }`.
    #   Each entry wraps the same `"compilation"` object {.find} returns.
    # @raise [AtlasRb::ForbiddenError] on a cross-owner listing without admin.
    #
    # @example My Sets
    #   AtlasRb::Compilation.list(nuid: "000000002")
    #
    # @example Another user's Sets (admin)
    #   AtlasRb::Compilation.list(owner: "000000002", nuid: "000000004")
    def self.list(owner: nil, page: nil, per_page: nil, nuid: nil, on_behalf_of: nil)
      params = {}
      params[:owner]    = owner    if owner
      params[:page]     = page     if page
      params[:per_page] = per_page if per_page
      AtlasRb::Mash.new(JSON.parse(
        connection(params, nuid, on_behalf_of: on_behalf_of).get(ROUTE)&.body
      ))
    end

    # Create a Compilation owned by the acting user.
    #
    # The depositor (owner) is stamped server-side from the authenticated
    # NUID — it is not a parameter and is immutable post-create. New Sets
    # are born private: empty ACLs, no staff default.
    #
    # @param title [String] the Set's title (required; blank is a 422).
    # @param description [String, nil] optional free-text description.
    # @param nuid [String, nil] the acting user's NUID, forwarded as the
    #   `User:` header — the created Set's owner. Required for
    #   cerberus-token requests.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the created `"compilation"` object, already unwrapped.
    # @raise [AtlasRb::CompilationError] if Atlas rejects the create (422 —
    #   e.g. a blank title).
    # @raise [AtlasRb::ForbiddenError] if the caller may not create Sets
    #   (guests cannot).
    #
    # @example
    #   AtlasRb::Compilation.create("Course readings",
    #                               description: "HIST 1101",
    #                               nuid: "000000002")
    def self.create(title, description: nil, nuid: nil, on_behalf_of: nil)
      params = { title: title }
      params[:description] = description if description
      AtlasRb::Mash.new(JSON.parse(
        connection(params, nuid, on_behalf_of: on_behalf_of).post(ROUTE)&.body
      ))["compilation"]
    end

    # Update a Compilation's title / description / ACL.
    #
    # Only the keys you pass are written. The `permissions:` hash replaces
    # all three grant lists at once (`read:` / `edit:` group lists plus
    # `edit_users:` NUIDs); the depositor is never writable. Server-side,
    # an ACL change emits a `permissions` audit event (no-op ACL writes are
    # suppressed); recipe membership has its own calls and emits nothing.
    #
    # @param id [String] the Compilation ID.
    # @param title [String, nil] new title.
    # @param description [String, nil] new description.
    # @param permissions [Hash, nil] ACL replacement, e.g.
    #   `{ read: ["public"], edit: [], edit_users: ["000000003"] }`.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"compilation"` object, already unwrapped.
    # @raise [AtlasRb::CompilationError] if Atlas rejects the update (422).
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights
    #   (owner / explicit grant / admin).
    #
    # @example Rename
    #   AtlasRb::Compilation.update("c-123", title: "Renamed", nuid: "000000002")
    #
    # @example Make public (the CERES case)
    #   AtlasRb::Compilation.update("c-123",
    #                               permissions: { read: ["public"], edit: [], edit_users: [] },
    #                               nuid: "000000002")
    def self.update(id, title: nil, description: nil, permissions: nil, nuid: nil, on_behalf_of: nil)
      params = {}
      params[:title]       = title       if title
      params[:description] = description if description
      params[:permissions] = permissions if permissions
      AtlasRb::Mash.new(JSON.parse(
        connection(params, nuid, on_behalf_of: on_behalf_of).patch(ROUTE + id)&.body
      ))["compilation"]
    end

    # Destroy a Compilation.
    #
    # Owner (or edit-grantee / admin) only. The recipe rows go with it; the
    # Works and Collections it referenced are untouched — a Set is a view,
    # not a container.
    #
    # @param id [String] the Compilation ID.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Faraday::Response] the raw response. Status `204` on success.
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights.
    #
    # @example
    #   AtlasRb::Compilation.destroy("c-123", nuid: "000000002")
    def self.destroy(id, nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).delete(ROUTE + id)
    end

    # Add an include-collection recipe line: everything under the
    # Collection (transitively) joins the Set's resolved contents.
    #
    # Idempotent — re-adding an included collection is a no-op. The noid
    # must resolve to a Collection: Communities and unknown ids are
    # rejected server-side as a 422.
    #
    # @param id [String] the Compilation ID.
    # @param collection_id [String] the Collection NOID to include.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"compilation"` object — the response is
    #   the full recipe, so chip counts refresh without a follow-up {.find}.
    # @raise [AtlasRb::CompilationError] if the noid is not a Collection (422).
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights.
    #
    # @example
    #   AtlasRb::Compilation.add_included_collection("c-123", "col-456", nuid: "000000002")
    def self.add_included_collection(id, collection_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ collection_id: collection_id }, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + id + '/included_collections')&.body
      ))["compilation"]
    end

    # Remove an include-collection recipe line.
    #
    # Idempotent — removing a collection that is not in the recipe is a
    # 200 no-op (nothing for a client to recover from).
    #
    # @param id [String] the Compilation ID.
    # @param collection_id [String] the Collection NOID to remove.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"compilation"` object.
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights.
    #
    # @example
    #   AtlasRb::Compilation.remove_included_collection("c-123", "col-456", nuid: "000000002")
    def self.remove_included_collection(id, collection_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + id + '/included_collections/' + collection_id)&.body
      ))["compilation"]
    end

    # Add an include-work recipe line: one Work, included individually.
    #
    # Idempotent. The noid must resolve to a Work; anything else is a 422.
    #
    # @param id [String] the Compilation ID.
    # @param work_id [String] the Work NOID to include.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"compilation"` object.
    # @raise [AtlasRb::CompilationError] if the noid is not a Work (422).
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights.
    #
    # @example
    #   AtlasRb::Compilation.add_included_work("c-123", "w-789", nuid: "000000002")
    def self.add_included_work(id, work_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ work_id: work_id }, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + id + '/included_works')&.body
      ))["compilation"]
    end

    # Remove an include-work recipe line. Idempotent.
    #
    # @param id [String] the Compilation ID.
    # @param work_id [String] the Work NOID to remove.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"compilation"` object.
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights.
    #
    # @example
    #   AtlasRb::Compilation.remove_included_work("c-123", "w-789", nuid: "000000002")
    def self.remove_included_work(id, work_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + id + '/included_works/' + work_id)&.body
      ))["compilation"]
    end

    # Set a Work aside: subtract it from the Set's resolved contents even
    # though an included collection covers it.
    #
    # Idempotent. The noid must resolve to a Work. Setting aside a Work
    # that no inclusion currently covers is legal — the recipe lines are
    # independent; the subtraction just matches nothing.
    #
    # @param id [String] the Compilation ID.
    # @param work_id [String] the Work NOID to set aside.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"compilation"` object.
    # @raise [AtlasRb::CompilationError] if the noid is not a Work (422).
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights.
    #
    # @example
    #   AtlasRb::Compilation.add_exclusion("c-123", "w-789", nuid: "000000002")
    def self.add_exclusion(id, work_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({ work_id: work_id }, nuid, on_behalf_of: on_behalf_of)
          .post(ROUTE + id + '/exclusions')&.body
      ))["compilation"]
    end

    # Put a set-aside Work back. Idempotent.
    #
    # @param id [String] the Compilation ID.
    # @param work_id [String] the Work NOID to restore to the resolved set.
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [Hash] the updated `"compilation"` object.
    # @raise [AtlasRb::ForbiddenError] if the caller lacks edit rights.
    #
    # @example
    #   AtlasRb::Compilation.remove_exclusion("c-123", "w-789", nuid: "000000002")
    def self.remove_exclusion(id, work_id, nuid: nil, on_behalf_of: nil)
      AtlasRb::Mash.new(JSON.parse(
        connection({}, nuid, on_behalf_of: on_behalf_of)
          .delete(ROUTE + id + '/exclusions/' + work_id)&.body
      ))["compilation"]
    end

    # Resolve a Compilation's recipe into the Works it currently denotes.
    #
    # Wraps `GET /compilations/<id>/contents` — included for completeness;
    # the endpoint's primary consumer is CERES (which calls Atlas directly),
    # and Cerberus resolves Set contents via its own Blacklight query.
    # Results are gated to what the caller may discover (public + the
    # caller's groups; admins see everything; tombstoned works excluded) —
    # the same semantics as Cerberus gated discovery.
    #
    # @param id [String] the Compilation ID.
    # @param page [Integer, nil] 1-indexed page number (default 1).
    # @param per_page [Integer, nil] page size (default 25, capped at 100).
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [AtlasRb::Mash] `{ "contents" => [...], "pagination" =>
    #   { "total", "page", "per_page", "pages" } }`. Each entry is a
    #   lightweight digest in the {Resource.find_many} vocabulary —
    #   `id` / `noid` / `klass` / `title` / `thumbnail`.
    # @raise [AtlasRb::ForbiddenError] if the caller may not read this Set.
    #
    # @example
    #   page = AtlasRb::Compilation.contents("c-123", nuid: "000000002")
    #   page.contents.map(&:noid)
    #   page.pagination.total
    def self.contents(id, page: nil, per_page: nil, nuid: nil, on_behalf_of: nil)
      params = {}
      params[:page]     = page     if page
      params[:per_page] = per_page if per_page
      AtlasRb::Mash.new(JSON.parse(
        connection(params, nuid, on_behalf_of: on_behalf_of).get(ROUTE + id + '/contents')&.body
      ))
    end
  end
end
