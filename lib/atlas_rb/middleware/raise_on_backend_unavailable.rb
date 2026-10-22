# frozen_string_literal: true

module AtlasRb
  module Middleware
    # Translates Atlas's dependency-outage answer into a typed Ruby exception.
    #
    # When Atlas cannot reach its database, its Solr index or its storage, it
    # answers `503 Service Unavailable` with the discriminator
    # `error: "backend_unavailable"`, a `dependency` key and a `Retry-After`
    # header. This middleware keys on the **status + discriminator pair** and
    # raises {AtlasRb::BackendUnavailableError}.
    #
    # Path-independent, like {RaiseOnReadOnlyMode}: an outage can answer any
    # request. A 503 without Atlas's envelope — a proxy while Atlas restarts —
    # passes through untouched, because that is a different condition.
    class RaiseOnBackendUnavailable < Faraday::Middleware
      # The discriminator Atlas renders. An exact-match wire contract.
      CODE = "backend_unavailable"

      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::BackendUnavailableError] on a 503 whose body carries
      #   `error: "backend_unavailable"`.
      # @return [void]
      def on_complete(env)
        return unless env.status == 503

        body = parse_json(env.body)
        return unless body.is_a?(Hash) && body["error"] == CODE

        raise AtlasRb::BackendUnavailableError.new(
          body["message"],
          code: body["error"],
          dependency: body["dependency"],
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
