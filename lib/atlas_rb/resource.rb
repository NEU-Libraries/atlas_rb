# frozen_string_literal: true

module AtlasRb
  class Resource
    extend AtlasRb::FaradayHelper

    def self.find(id)
      result = JSON.parse(connection({}).get('/resources/' + id)&.body)
      { "klass" => result.first[0].capitalize,
        "resource" => result.first[1] }
    end
  end
end
