# frozen_string_literal: true

module AtlasRb
  # The repository-wide read-only window (`GET` / `PUT /maintenance`).
  #
  # An operator opens the window, Atlas keeps serving reads and refuses every
  # write with a `503` carrying `error: "read_only_mode"`, migrations run, the
  # operator closes it. Three doors open the same window: Cerberus's admin hub,
  # Atlas's `maintenance:open` rake task, and the deploy orchestrator.
  #
  # ## Why the flag lives in Atlas
  #
  # A window has to hold across both apps. A Cerberus-held flag is bypassed by
  # any direct API caller, including a personal-access token minted by
  # `POST /nuid`, so the flag is a row in Atlas and the floor that enforces it
  # is Atlas's own authorization layer.
  #
  # ## Reading versus writing
  #
  # {.read} sits on Atlas's authenticated read floor and is answered even while
  # the window is open — a client that could not read the flag could not honour
  # it. {.write} is `:system`-gated, matching how the token endpoints gate an
  # operator action, so it goes out over {FaradayHelper#system_connection}.
  #
  # Refused writes surface as {AtlasRb::ReadOnlyModeError} via
  # {Middleware::RaiseOnReadOnlyMode}, on every binding and every path. Poll
  # {.read} to render a banner before a caller trips that.
  class Maintenance
    extend AtlasRb::FaradayHelper

    # Read the window's state (`GET /maintenance`).
    #
    # Cheap and safe to poll behind a short-TTL cache; Cerberus renders its
    # banner and its client-side write gate from this.
    #
    # @param nuid [String, nil] the acting NUID, signed into the assertion `sub`
    #   on the relay path. Optional only in BYO-JWT mode or when the host
    #   configures {AtlasRb.config#default_nuid}; the read sits behind Atlas's
    #   authenticated read floor, so it needs a principal like any other read.
    # @param on_behalf_of [String, nil] optional NUID carried as a signed `obo`
    #   claim.
    # @return [AtlasRb::Mash] `read_only` (Boolean), `source`
    #   (`"operator"` / `"deploy"` / nil), `since` (ISO-8601 or nil), `message`
    #   (String or nil), and `retry_after` (Integer seconds).
    def self.read(nuid: nil, on_behalf_of: nil)
      response = connection({}, nuid, on_behalf_of: on_behalf_of).get("/maintenance")
      AtlasRb::Mash.new(JSON.parse(response.body))
    end

    # Open or close the window (`PUT /maintenance`). System-gated in Atlas.
    #
    # `source` names which door is acting, and Atlas enforces one rule with it:
    # a `"deploy"` close is refused when an `"operator"` opened the window, so a
    # deploy that finishes cannot close a window a human opened by hand. The
    # refusal is not an error — Atlas answers `200` with the *unchanged* state,
    # so read `read_only` off the return value rather than assuming the write
    # took. An `"operator"` close clears either.
    #
    # @param read_only [Boolean] true to open the window, false to close it.
    # @param source [String] `"operator"` (a human at the hub or the console) or
    #   `"deploy"` (the deploy orchestrator).
    # @param message [String, nil] operator note for the client-side banner.
    # @param retry_after [Integer, nil] seconds a refused caller should wait;
    #   Atlas mirrors it into the `Retry-After` header on every refusal.
    # @return [AtlasRb::Mash] the window's state after the write — which is the
    #   state *before* it when a deploy close was refused.
    def self.write(read_only:, source:, message: nil, retry_after: nil)
      body = { read_only: read_only, source: source }
      body[:message] = message if message
      body[:retry_after] = retry_after if retry_after

      AtlasRb::Mash.new(JSON.parse(system_connection.put("/maintenance", body.to_json).body))
    end
  end
end
