# frozen_string_literal: true

module AtlasRb
  # Atlas's own operational figures. Admin- or `:system`-gated in Atlas.
  class Metrics
    extend AtlasRb::FaradayHelper

    # Seconds to wait for a socket to open.
    OPEN_TIMEOUT = 2

    # Seconds to wait for the report. It reads at most 120 small Redis hashes,
    # so a slower answer means Atlas is struggling, and an admin page should
    # not wait on it.
    READ_TIMEOUT = 5

    # How long Atlas took to serve its own requests (`GET /metrics/latency`).
    #
    # Measured inside Atlas, from when a request enters its Rack stack until
    # the app returns the response — the same span as the `x-runtime` header.
    # So it includes time a request spent waiting inside Atlas behind
    # concurrent ones, and leaves out time queued for a Puma thread, the
    # network, and the caller's own waiting. A caller that also times its
    # Atlas calls can subtract to see how much of its wait was its own. The
    # percentiles are interpolated from histogram buckets, so they are
    # approximate.
    #
    # No retry, and a fresh socket per call: like {AtlasRb::Health.read}, it is
    # polled rarely and should fail fast rather than hide a struggling Atlas.
    #
    # @param minutes [Integer] the window, 1 to 120. Atlas clamps it.
    # @param nuid [String, nil] the acting NUID, signed into the assertion
    #   `sub`. It must name an admin; falls through to
    #   {AtlasRb.config#default_nuid}.
    # @param on_behalf_of [String, nil] optional NUID carried as a signed `obo`
    #   claim.
    # @return [AtlasRb::Mash] `window_minutes`, `calls`, `server_errors`,
    #   `mean_ms`, `p50_ms`, `p95_ms`, `p99_ms` (Integer, or nil with no calls),
    #   and `slowest_actions`, an Array of `action` / `calls` / `p95_ms`.
    # @raise [AtlasRb::BackendUnavailableError] when Atlas answers that Redis,
    #   which holds the figures, is down (`dependency == "cache"`).
    # @raise [AtlasRb::ResourceError] on any other non-200, notably a `403`
    #   for a caller who is not an admin.
    # @raise [Faraday::ConnectionFailed, Faraday::TimeoutError] when Atlas does
    #   not answer at all.
    #
    # @example
    #   latency = AtlasRb::Metrics.latency(minutes: 15, nuid: current_user.nuid)
    #   latency.p95_ms  # => 98
    def self.latency(minutes: 60, nuid: nil, on_behalf_of: nil)
      resp = metrics_connection(nuid, on_behalf_of).get("/metrics/latency", minutes: minutes)
      return AtlasRb::Mash.new(JSON.parse(resp.body)) if resp.status == 200

      raise AtlasRb::ResourceError.new("#{request_target(resp)} → #{resp.status}: #{resp.body}", response: resp)
    end

    class << self
      private

      def metrics_connection(nuid, on_behalf_of)
        headers = auth_headers(nuid, on_behalf_of).merge("Content-Type" => "application/json")
        Faraday.new(url: ENV.fetch("ATLAS_URL", nil), headers: headers) do |f|
          f.options.open_timeout = OPEN_TIMEOUT
          f.options.timeout      = READ_TIMEOUT
          instrument(f)
          f.use AtlasRb::Middleware::RaiseOnBackendUnavailable
          f.adapter :net_http
        end
      end
    end
  end
end
