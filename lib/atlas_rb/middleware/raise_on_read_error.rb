# frozen_string_literal: true

module AtlasRb
  module Middleware
    # Raises {AtlasRb::ResourceError} when a read comes back non-2xx, so no
    # read binding can hand an error body back as if it were data.
    #
    # ## Why a middleware rather than a guard per binding
    #
    # {AtlasRb::Resource.fetch_resource} enforces this contract for the typed
    # single-resource `find`s, but a binding has to opt in by routing through
    # it, and the read surface is about thirty methods wide. The failures that
    # come of forgetting are the ones hardest to attribute: `JSON.parse` on an
    # error envelope yields a Hash with no payload key, so the caller
    # dereferences `nil` far from the cause; a binding returning a raw body
    # hands the error text to whatever renders it. Enforcing at the transport
    # means a binding cannot forget.
    #
    # ## Scope: reads only
    #
    # Keyed on the request method, because {SAFE_METHODS} is what "a read" means
    # on the wire. The write path has its own guard
    # ({AtlasRb::Resource.write_resource}, which names the verb and path in a
    # {AtlasRb::NotFoundError}), and several write bindings — `tombstone`,
    # `destroy`, `complete` — deliberately return the raw response so their
    # caller can read a `422` discriminator Atlas owns as a wire contract.
    # Raising on those would take that away.
    #
    # The two `POST`-shaped reads (`Resource.find_many`,
    # `Blob.find_many_versions`) are out of reach here, so they call
    # {AtlasRb::FaradayHelper#read_body} — which applies the same mapping —
    # directly.
    #
    # ## Statuses that pass through
    #
    # - `404` — "absent" is a legitimate answer to a read, so the binding
    #   answers `nil`. That holds for a list read too: "no such container" and
    #   "an empty container" mean different things to a UI.
    # - `410` — a tombstone arrives as `410 Gone` *with* its full body, so it is
    #   a returnable answer rather than an error envelope.
    #
    # ## Ordering
    #
    # Register this **before** the typed translators
    # ({RaiseOnStaleResource}, {RaiseOnResourceError}, {RaiseOnReadOnlyMode}).
    # Faraday runs `on_complete` innermost-first, so the handler registered
    # earliest runs last — which is where this one belongs: a maintenance `503`
    # must stay a {AtlasRb::ReadOnlyModeError} and a refused re-parent must stay
    # a {AtlasRb::ForbiddenError}, not become a generic {AtlasRb::ResourceError}.
    class RaiseOnReadError < Faraday::Middleware
      # Request methods this middleware treats as reads.
      SAFE_METHODS = %i[get head].freeze

      # Read statuses that are answers rather than failures.
      PASS_THROUGH = [404, 410].freeze

      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::ResourceError] on a non-2xx read other than
      #   `404` / `410`, carrying Atlas's status and body.
      # @return [void]
      def on_complete(env)
        return unless SAFE_METHODS.include?(env.method)
        return if env.status < 400 || PASS_THROUGH.include?(env.status)
        return if streaming?(env)

        raise AtlasRb::ResourceError.new(
          "#{env.method.to_s.upcase} #{env.url&.path} → #{env.status}: #{env.body}",
          response: env.response
        )
      end

      private

      # A streaming read has already written its chunks to the caller by the
      # time `on_complete` runs, so raising here would be too late to stop the
      # damage and would take away the status the caller was handed instead.
      # {AtlasRb::Blob.content} and {AtlasRb::Blob.version_content} return
      # `{ status:, headers: }` and check it themselves.
      def streaming?(env)
        !env.request&.on_data.nil?
      end
    end
  end
end
