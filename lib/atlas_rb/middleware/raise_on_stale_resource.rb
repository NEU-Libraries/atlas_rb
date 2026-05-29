# frozen_string_literal: true

module AtlasRb
  # Faraday middleware namespace.
  module Middleware
    # Translates Atlas's structured optimistic-lock conflict response into a
    # typed Ruby exception.
    #
    # Atlas surfaces an exhausted-retry (or retry-unsafe) optimistic-lock
    # conflict as an HTTP `409 Conflict` whose JSON body carries the
    # discriminator `error: "stale_resource"`. This middleware keys on the
    # **status + discriminator pair** and raises {AtlasRb::StaleResourceError},
    # carrying the envelope's `resource_id` and `action` through so callers'
    # failure logs are useful without the full response.
    #
    # It is intentionally narrow: any other status, or a 409 without the
    # discriminator, passes through untouched so the caller still sees the
    # response as a Mash (see {AtlasRb::StaleResourceError} for the rationale —
    # atlas_rb stays a thin Faraday binding and translates only the one wire
    # signal Cerberus jobs need to discriminate on).
    class RaiseOnStaleResource < Faraday::Middleware
      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::StaleResourceError] on a 409 whose body carries
      #   `error: "stale_resource"`.
      # @return [void]
      def on_complete(env)
        return unless env.status == 409

        body = parse_json(env.body)
        return unless body.is_a?(Hash) && body["error"] == "stale_resource"

        raise AtlasRb::StaleResourceError.new(
          body["message"] || "Atlas reported a stale-resource conflict",
          resource_id: body["resource_id"],
          action: body["action"]
        )
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
