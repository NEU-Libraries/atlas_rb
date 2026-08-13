# frozen_string_literal: true

module AtlasRb
  module Middleware
    # Translates Atlas's structured re-parent / linked-member rejections into
    # typed Ruby exceptions, so the resource bindings don't silently swallow
    # the error envelope.
    #
    # The re-parent and linked-member bindings unwrap their success payload by
    # a fixed key (`["collection"]` / `["work"]` / `["community"]`, or the
    # bare linked-member array). On a `4xx` that key is absent, so the binding
    # would return `nil` and discard Atlas's machine-readable `error` /
    # `message`. This middleware keys on the **request path + status** and
    # raises a typed error carrying the envelope through, parallel to
    # {RaiseOnStaleResource}.
    #
    # It is intentionally narrow — it only fires on the re-parent
    # (`.../parent`), linked-member (`.../linked_members...`) and association
    # (`.../associations...`) write paths,
    # the Compilation surface (`/compilations...`), the derivative-permissions
    # write (`.../derivative_permissions`), the container-create endpoints
    # ({CREATE_PATHS}), and binary uploads (`/files...`, `/file_sets...`), and
    # only on `403` / `422` bodies carrying an `error` discriminator. The upload
    # branch is further gated on a fixity discriminator ({FIXITY_CODES}), so a
    # `422` on those paths with any other `error` (or `403`s on uploads, which
    # stay raw) passes through untouched.
    # Everything else (other paths, other statuses, a `422` whose body uses a
    # different discriminator such as `tombstone`'s `code: "has_live_children"`)
    # passes through untouched, so atlas_rb stays a thin Faraday binding that
    # translates only the wire signals callers genuinely need to discriminate.
    #
    # The ACL branch is keyed on the `error` code ({PERMISSIONS_CODES}) rather
    # than a path, because the write it guards is the plain resource `PATCH`
    # whose other rejections (tombstone's `has_live_children`) must keep passing
    # through — a path rule couldn't tell them apart.
    #
    # Mapping:
    # - `403` on a re-parent/linked/Compilation/derivative-permissions/create path → {AtlasRb::ForbiddenError}
    # - `422` on `.../parent` → {AtlasRb::ReparentError} (`error`/`resource_id`)
    # - `422` on `.../linked_members...` → {AtlasRb::LinkedMemberError}
    # - `422` on `.../associations...` → {AtlasRb::WorkAssociationError}
    # - `422` on `/compilations...` → {AtlasRb::CompilationError}
    # - `422` on `.../derivative_permissions` → {AtlasRb::DerivativePermissionsError}
    # - `422` + an ACL discriminator anywhere → {AtlasRb::PermissionsError}
    # - `422` + a fixity discriminator on `/files...` / `/file_sets...` →
    #   {AtlasRb::FixityMismatchError}
    class RaiseOnResourceError < Faraday::Middleware
      # Upload-path `422` discriminators this middleware translates; any other
      # `error` on those paths passes through (Atlas owns these as a wire contract).
      FIXITY_CODES = %w[fixity_mismatch unsupported_digest_algorithm].freeze

      # ACL-invariant `422` discriminators, translated wherever they appear:
      # Atlas raises them from the shared metadata-PATCH funnel, so they can
      # arrive on any resource's `PATCH /{type}/:id`.
      PERMISSIONS_CODES = %w[visibility_exceeds_parent].freeze

      # The container-create endpoints, matched exactly (no trailing id) and only
      # on `POST`, so neither a member action under the same prefix
      # (`/collections/:id/tombstone`, whose `422` must pass through) nor the
      # index `GET` on the same path can be caught by mistake. A `403` here means
      # the caller holds no edit rights on the destination container.
      CREATE_PATHS = %w[/works /collections /communities].freeze

      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::ForbiddenError] on a 403 to a re-parent/linked/Compilation/create path.
      # @raise [AtlasRb::ReparentError] on a 422 to a re-parent path.
      # @raise [AtlasRb::LinkedMemberError] on a 422 to a linked-member path.
      # @raise [AtlasRb::WorkAssociationError] on a 422 to an association path.
      # @raise [AtlasRb::CompilationError] on a 422 to a Compilation path.
      # @raise [AtlasRb::DerivativePermissionsError] on a 422 to a derivative-permissions path.
      # @raise [AtlasRb::PermissionsError] on a 422 carrying an ACL-invariant discriminator.
      # @raise [AtlasRb::FixityMismatchError] on a 422 + fixity discriminator to an upload path.
      # @return [void]
      def on_complete(env)
        return unless [403, 422].include?(env.status)

        path        = env.url&.path.to_s
        reparent    = path.end_with?("/parent")
        linked      = path.include?("/linked_members")
        association = path.include?("/associations")
        compilation = path.start_with?("/compilations")
        deriv_perms = path.end_with?("/derivative_permissions")
        create      = env.method.to_s == "post" && CREATE_PATHS.include?(path.chomp("/"))
        upload      = path.start_with?("/files") || path.start_with?("/file_sets")

        body = parse_json(env.body)
        return unless body.is_a?(Hash) && body["error"]

        # Path-independent: the ACL invariants ride the shared metadata PATCH,
        # so the code is the only reliable signal.
        if env.status == 422 && PERMISSIONS_CODES.include?(body["error"])
          raise AtlasRb::PermissionsError.new(
            body["message"] || "Atlas rejected the permissions write",
            code: body["error"],
            resource_id: body["resource_id"]
          )
        end

        return unless reparent || linked || association || compilation || deriv_perms || create || upload

        if env.status == 403
          # 403s on upload paths stay raw — acting-as/authz isn't an upload concern here.
          return unless reparent || linked || association || compilation || deriv_perms || create

          raise AtlasRb::ForbiddenError.new(
            body["message"] || "Atlas refused the request",
            code: body["error"],
            action: body["action"],
            subject: body["subject"]
          )
        elsif reparent
          raise AtlasRb::ReparentError.new(
            body["message"] || "Atlas rejected the re-parent",
            code: body["error"],
            resource_id: body["resource_id"]
          )
        elsif linked
          raise AtlasRb::LinkedMemberError.new(
            body["message"] || "Atlas rejected the linked-member write",
            code: body["error"],
            resource_id: body["resource_id"]
          )
        elsif association
          raise AtlasRb::WorkAssociationError.new(
            body["message"] || "Atlas rejected the association write",
            code: body["error"],
            resource_id: body["resource_id"]
          )
        elsif compilation
          raise AtlasRb::CompilationError.new(
            body["message"] || "Atlas rejected the compilation write",
            code: body["error"],
            resource_id: body["resource_id"]
          )
        elsif deriv_perms
          raise AtlasRb::DerivativePermissionsError.new(
            body["message"] || "Atlas rejected the derivative-permissions policy",
            code: body["error"],
            resource_id: body["resource_id"]
          )
        elsif FIXITY_CODES.include?(body["error"])
          raise AtlasRb::FixityMismatchError.new(
            body["message"] || "Atlas rejected the upload (fixity)",
            code: body["error"],
            resource_id: body["resource_id"]
          )
        end
      end

      private

      def parse_json(body)
        return body if body.is_a?(Hash)

        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
