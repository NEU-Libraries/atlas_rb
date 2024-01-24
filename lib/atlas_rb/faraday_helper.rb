# frozen_string_literal: true

module AtlasRb
  module FaradayHelper
    def connection(params)
      Faraday.new(
        url: ENV.fetch("ATLAS_URL", nil),
        params: params,
        headers: { "Content-Type" => "application/json" }
      ) do |f|
        f.use Faraday::FollowRedirects::Middleware
        f.response :follow_redirects
        f.adapter Faraday.default_adapter
      end
    end

    def multipart(_params)
      Faraday.new(url: ENV.fetch("ATLAS_URL", nil)) do |f|
        f.request :multipart
        f.request :url_encoded
      end
    end
  end
end
