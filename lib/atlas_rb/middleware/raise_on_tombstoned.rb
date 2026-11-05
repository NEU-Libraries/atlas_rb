# frozen_string_literal: true

module AtlasRb
  module Middleware
    # Translates Atlas's tombstone refusal into {AtlasRb::TombstonedError}.
    #
    # Atlas answers `410` with `error: "tombstoned"` when it withholds a file's
    # bytes or a tombstoned Work's file list. Without this the refusal reaches
    # {Middleware::RaiseOnReadError}, which lets every `410` through, and a list
    # binding maps over the error envelope as if it were the list.
    #
    # Keyed on the **status + discriminator pair**. A `410` that carries the
    # resource's own body — {AtlasRb::Work.find} on a tombstoned Work — is an
    # answer, not a refusal, and passes through untouched.
    #
    # A streamed read never reaches here with a body: its chunks go to
    # `on_data`. {AtlasRb::Blob.content} checks the status itself.
    class RaiseOnTombstoned < Faraday::Middleware
      # @param env [Faraday::Env] the completed response environment.
      # @raise [AtlasRb::TombstonedError] on a `410` whose body carries
      #   `error: "tombstoned"`.
      # @return [void]
      def on_complete(env)
        return unless env.status == 410

        envelope = AtlasRb::TombstonedError.envelope(env.body)
        raise AtlasRb::TombstonedError.new(envelope, response: env.response) if envelope
      end
    end
  end
end
