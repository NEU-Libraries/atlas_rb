# frozen_string_literal: true

require "hashie"

module AtlasRb
  # Shared `Hashie::Mash` subclass used to wrap parsed JSON responses so
  # callers can use dot access (`work.id`) alongside string-keyed access
  # (`work["id"]`).
  #
  # `disable_warnings` silences Hashie's stderr noise when an Atlas
  # response key collides with an existing `Hash` method (e.g. `class`,
  # `type`, `id`).
  class Mash < Hashie::Mash
    disable_warnings
  end
end
