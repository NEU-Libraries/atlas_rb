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
    # (`.../parent`) and linked-member (`.../linked_members...`) write paths
    # and the Compilation surface (`/compilations...`), and only on
    # `403` / `422` bodies carrying an `error` discriminator.
    # Everything else (other paths, other statuses, a `422` whose body uses a
    # different discriminator such as `tombstone`'s `code: "has_live_children"`)
    # passes through untouched, so atlas_rb stays a thin Faraday binding that
    # translates only the wire signals callers genuinely need to discriminate.
    #
    # Mapping:
    # - `403` (any covered path) → {AtlasRb::ForbiddenError} (`error`/`action`/`subject`)
    # - `422` on `.../parent` → {AtlasRb::ReparentError} (`error`/`resource_id`)
    # - `422` on `.../linked_members...` → {AtlasRb::LinkedMemberError}
    # - `422` on `/compilations...` → {AtlasRb::CompilationError}
    class RaiseOnResourceError < Faraday::Middleware
      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::ForbiddenError] on a 403 to a covered path.
      # @raise [AtlasRb::ReparentError] on a 422 to a re-parent path.
      # @raise [AtlasRb::LinkedMemberError] on a 422 to a linked-member path.
      # @raise [AtlasRb::CompilationError] on a 422 to a Compilation path.
      # @return [void]
      def on_complete(env)
        return unless env.status == 403 || env.status == 422

        path        = env.url&.path.to_s
        reparent    = path.end_with?("/parent")
        linked      = path.include?("/linked_members")
        compilation = path.start_with?("/compilations")
        return unless reparent || linked || compilation

        body = parse_json(env.body)
        return unless body.is_a?(Hash) && body["error"]

        if env.status == 403
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
        else
          raise AtlasRb::CompilationError.new(
            body["message"] || "Atlas rejected the compilation write",
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
