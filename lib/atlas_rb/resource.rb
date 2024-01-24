# frozen_string_literal: true

module AtlasRb
  class Resource
    extend AtlasRb::FaradayHelper

    def self.find(id)
      JSON.parse(connection({}).get('/resources/' + id)&.body)
    end
  end
end
