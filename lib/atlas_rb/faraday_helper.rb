# frozen_string_literal: true

module AtlasRb
  # HTTP transport helpers shared by every resource class.
  #
  # Every Atlas request reads two environment variables:
  #
  # - `ATLAS_URL`   — base URL of the Atlas API (e.g. `https://atlas.example.edu`).
  # - `ATLAS_TOKEN` — bearer token used in the `Authorization` header.
  #
  # Most calls also identify the acting user via a `User: NUID <nuid>` header.
  # Resource classes typically pass `nuid = nil` (anonymous / system context);
  # {AtlasRb::Authentication} is the only place where a real NUID is currently
  # threaded through.
  #
  # The module is mixed in via `extend`, so its methods become class methods on
  # the host (e.g. `AtlasRb::Work.connection({})`).
  module FaradayHelper
    # Build a JSON-content Faraday connection to the Atlas API.
    #
    # @param params [Hash] query-string / body params to attach to the request.
    #   Resource classes use this to pass things like `parent_id:`, `work_id:`,
    #   or `metadata:` without manually serializing.
    # @param nuid [String, nil] optional Northeastern University ID to send in
    #   the `User` header. Defaults to `nil` (no NUID context).
    # @return [Faraday::Connection] a connection that follows redirects and
    #   uses Faraday's default adapter.
    #
    # @example Fetching a community
    #   AtlasRb::Community.connection({}).get('/communities/abc123')
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

    # Build a multipart Faraday connection used for binary and XML uploads.
    #
    # The same `ATLAS_URL` / `ATLAS_TOKEN` env vars apply. Unlike {#connection},
    # the `Content-Type` is set automatically by the multipart middleware, and
    # callers pass a payload hash whose values may include
    # `Faraday::Multipart::FilePart` instances.
    #
    # @param nuid [String, nil] optional NUID for the `User` header.
    # @return [Faraday::Connection] a multipart-aware connection.
    #
    # @example Posting a binary blob
    #   payload = {
    #     work_id: "w-123",
    #     binary: Faraday::Multipart::FilePart.new(File.open("scan.pdf"),
    #                                               "application/octet-stream",
    #                                               "scan.pdf")
    #   }
    #   AtlasRb::Blob.multipart({}).post('/files/', payload)
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
