# frozen_string_literal: true

module AtlasRb
  # Atlas's readiness report (`GET /health`): whether it can reach its database,
  # its Solr index, its storage and its cache.
  #
  # Atlas answers `200` when every required dependency answers and `503` when
  # one does not, with the same body either way:
  #
  #   { "status" => "degraded", "database" => "ok", "index" => "unavailable",
  #     "storage" => "ok", "cache" => "ok" }
  #
  # The endpoint is unauthenticated, so this sends no credential, and works
  # without a signing key or `ATLAS_JWT` configured.
  #
  # Not to be confused with `GET /up`, the liveness route the orchestrator
  # polls; it has no binding.
  class Health
    extend AtlasRb::FaradayHelper

    # Seconds to wait for a socket to open.
    OPEN_TIMEOUT = 2

    # Seconds to wait for the report. Atlas bounds each of its own probes, so a
    # slower answer means Atlas itself is struggling. Short enough to answer
    # inside a monitor's own deadline (Nagios's `check_http` defaults to 10s).
    READ_TIMEOUT = 5

    # Read the report.
    #
    # A `503` here is an answer, not an error, so it is returned like a `200`;
    # read `status` off the result. There is no retry: a probe must answer
    # faster than its poller times out, and a retry would hide the very
    # flakiness it exists to show.
    #
    # @param timeout [Numeric] seconds to wait for the report.
    # @return [AtlasRb::Mash] `status` (`"ok"` / `"degraded"` /
    #   `"unavailable"`), and `database`, `index`, `storage` (`"ok"` /
    #   `"unavailable"`) and `cache` (`"ok"` / `"unavailable"` / `"disabled"`).
    # @raise [Faraday::ConnectionFailed, Faraday::TimeoutError] when Atlas
    #   does not answer at all.
    # @raise [AtlasRb::ResourceError] when something answers that is not
    #   Atlas's report: a `404` from an Atlas that predates the endpoint, or a
    #   proxy's `502` with an HTML body.
    def self.read(timeout: READ_TIMEOUT)
      resp = health_connection(timeout).get("/health")
      report = parse_report(resp)
      return AtlasRb::Mash.new(report) if report

      raise AtlasRb::ResourceError.new("#{request_target(resp)} → #{resp.status}: #{resp.body}", response: resp)
    end

    class << self
      private

      # A fresh socket per call rather than the shared pool. With no retry, a
      # pooled socket the server had closed would report a healthy Atlas as
      # down; a probe runs far too rarely for the handshake to matter.
      def health_connection(timeout)
        Faraday.new(url: ENV.fetch("ATLAS_URL", nil)) do |f|
          f.options.open_timeout = OPEN_TIMEOUT
          f.options.timeout      = timeout
          instrument(f)
          f.adapter :net_http
        end
      end

      def parse_report(resp)
        return nil unless [200, 503].include?(resp.status)

        body = JSON.parse(resp.body.to_s)
        body.is_a?(Hash) && body.key?("status") ? body : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
