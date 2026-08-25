# frozen_string_literal: true

module AtlasRb
  module Middleware
    # Translates Atlas's maintenance-window refusal into a typed Ruby exception.
    #
    # Atlas refuses every write-shaped action while the repository-wide
    # read-only window is open, answering `503 Service Unavailable` with the
    # discriminator `error: "read_only_mode"` and a `Retry-After` header. This
    # middleware keys on the **status + discriminator pair** and raises
    # {AtlasRb::ReadOnlyModeError}.
    #
    # ## Why path-independent
    #
    # Modelled on {RaiseOnStaleResource}, not {RaiseOnResourceError}. A
    # maintenance window refuses writes on *every* path, so a path-keyed rule
    # would have to enumerate the whole write surface and would go stale the
    # moment Atlas grows an endpoint.
    #
    # ## Why the discriminator matters
    #
    # A 503 from a reverse proxy while Atlas restarts carries no JSON body. That
    # is a different condition with a different remedy, and it keeps passing
    # through untouched — only Atlas's own envelope raises.
    class RaiseOnReadOnlyMode < Faraday::Middleware
      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::ReadOnlyModeError] on a 503 whose body carries
      #   `error: "read_only_mode"`.
      # @return [void]
      def on_complete(env)
        return unless env.status == 503

        body = parse_json(env.body)
        return unless body.is_a?(Hash) && body["error"] == "read_only_mode"

        raise AtlasRb::ReadOnlyModeError.new(
          body["message"],
          code: body["error"],
          retry_after: env.response_headers&.[]("retry-after")&.to_i
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
