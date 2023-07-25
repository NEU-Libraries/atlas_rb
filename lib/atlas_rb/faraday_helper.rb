# frozen_string_literal: true

require 'faraday'

module AtlasRb
  module FaradayHelper
    def connection(params)
      Faraday.new(
        url: ENV["ATLAS_URL"],
        params: params,
        headers: {'Content-Type' => 'application/json'}
      )
    end
  end
end
