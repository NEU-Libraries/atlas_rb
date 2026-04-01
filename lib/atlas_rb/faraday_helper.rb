# frozen_string_literal: true

module AtlasRb
  module FaradayHelper
    def connection(params, nuid=nil)
      Faraday.new(
        url: ENV.fetch("ATLAS_URL", nil),
        params: params,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{ENV.fetch("ATLAS_TOKEN", nil)}",
          "User" => "NUID #{nuid}"
        }
      ) do |f|
        f.response :follow_redirects
        f.adapter Faraday.default_adapter
      end
    end

    def multipart(nuid=nil)
      Faraday.new(
        url: ENV.fetch("ATLAS_URL", nil),
        headers: {
          "Authorization" => "Bearer #{ENV.fetch("ATLAS_TOKEN", nil)}",
          "User" => "NUID #{nuid}"
        }
      ) do |f|
        f.request :multipart
        f.request :url_encoded
      end
    end
  end
end
