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
    # (`.../parent`) and linked-member (`.../linked_members...`) write paths,
    # the Compilation surface (`/compilations...`), and binary uploads
    # (`/files...`, `/file_sets...`), and only on `403` / `422` bodies carrying
    # an `error` discriminator. The upload branch is further gated on a fixity
    # discriminator ({FIXITY_CODES}), so a `422` on those paths with any other
    # `error` (or `403`s on uploads, which stay raw) passes through untouched.
    # Everything else (other paths, other statuses, a `422` whose body uses a
    # different discriminator such as `tombstone`'s `code: "has_live_children"`)
    # passes through untouched, so atlas_rb stays a thin Faraday binding that
    # translates only the wire signals callers genuinely need to discriminate.
    #
    # Mapping:
    # - `403` on a re-parent/linked/Compilation path → {AtlasRb::ForbiddenError}
    # - `422` on `.../parent` → {AtlasRb::ReparentError} (`error`/`resource_id`)
    # - `422` on `.../linked_members...` → {AtlasRb::LinkedMemberError}
    # - `422` on `/compilations...` → {AtlasRb::CompilationError}
    # - `422` + a fixity discriminator on `/files...` / `/file_sets...` →
    #   {AtlasRb::FixityMismatchError}
    class RaiseOnResourceError < Faraday::Middleware
      # Upload-path `422` discriminators this middleware translates; any other
      # `error` on those paths passes through (Atlas owns these as a wire contract).
      FIXITY_CODES = %w[fixity_mismatch unsupported_digest_algorithm].freeze

      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::ForbiddenError] on a 403 to a re-parent/linked/Compilation path.
      # @raise [AtlasRb::ReparentError] on a 422 to a re-parent path.
      # @raise [AtlasRb::LinkedMemberError] on a 422 to a linked-member path.
      # @raise [AtlasRb::CompilationError] on a 422 to a Compilation path.
      # @raise [AtlasRb::FixityMismatchError] on a 422 + fixity discriminator to an upload path.
      # @return [void]
      def on_complete(env)
        return unless [403, 422].include?(env.status)

        path        = env.url&.path.to_s
        reparent    = path.end_with?("/parent")
        linked      = path.include?("/linked_members")
        compilation = path.start_with?("/compilations")
        upload      = path.start_with?("/files") || path.start_with?("/file_sets")
        return unless reparent || linked || compilation || upload

        body = parse_json(env.body)
        return unless body.is_a?(Hash) && body["error"]

        if env.status == 403
          # 403s on upload paths stay raw — acting-as/authz isn't an upload concern here.
          return unless reparent || linked || compilation

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
        elsif compilation
          raise AtlasRb::CompilationError.new(
            body["message"] || "Atlas rejected the compilation write",
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
