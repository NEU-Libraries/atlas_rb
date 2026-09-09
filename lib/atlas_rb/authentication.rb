# frozen_string_literal: true

module AtlasRb
  # User-facing identity lookups against the Atlas API.
  #
  # Unlike the resource classes, {Authentication} threads a real NUID into
  # {FaradayHelper#connection}'s second positional argument. On the relay-signing
  # path that NUID is signed into the assertion `sub`; Atlas resolves the acting
  # user and their group memberships from the proven `sub`.
  #
  # No login round-trip happens here today; auth is assumed to be already
  # provisioned out-of-band (a configured signing key, or `ATLAS_JWT`). The
  # commented-out code in this file reflects an older flow where a `/token`
  # endpoint exchanged an NUID for a session token.
  class Authentication
    extend AtlasRb::FaradayHelper

    # Look up the Atlas user record for an NUID.
    #
    # A NUID can hold several accounts (a person's staff/student logins). Pass
    # `email:` to act as — and read back — a specific one; it rides as a signed
    # `acct` claim so `GET /user` resolves that account. Omit it and Atlas
    # returns the person's preferred account.
    #
    # @param nuid [String] the user's Northeastern University ID.
    # @param email [String, nil] optional account email to act as (the `acct`
    #   selector); nil resolves the preferred account.
    # @return [AtlasRb::Mash, nil] the user record returned by `GET /user`,
    #   including at minimum `"id"`, `"name"`, and `"groups"`.
    #   `nil` when Atlas answers `404` — nothing is there to read, or, with a
    #   misconfigured `ATLAS_URL`, the route is not Atlas's at all.
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` / `410`
    #   (an auth or validation envelope, a `5xx`, a proxy's `503`), carrying
    #   Atlas's status and body so the failure is attributable at the boundary.
    #
    # @example
    #   AtlasRb::Authentication.login("001234567")
    #   # => { "id" => 42, "name" => "Jane Doe", "groups" => [...] }
    def self.login(nuid, email: nil)
      read_body(connection({}, nuid, account: email).get('/user')) { |body| AtlasRb::Mash.new(body) }
    end

    # Fetch only the group memberships for an NUID.
    #
    # Convenience wrapper around the same `GET /user` call as {.login}; useful
    # when authorization checks only need group names.
    #
    # @param nuid [String] the user's Northeastern University ID.
    # @return [Array<Hash>, nil] the `"groups"` array from the user record.
    #   `nil` when Atlas answers `404` — nothing is there to read, or, with a
    #   misconfigured `ATLAS_URL`, the route is not Atlas's at all.
    # @raise [AtlasRb::ResourceError] on any non-2xx other than `404` / `410`
    #   (an auth or validation envelope, a `5xx`, a proxy's `503`), carrying
    #   Atlas's status and body so the failure is attributable at the boundary.
    #
    # @example
    #   AtlasRb::Authentication.groups("001234567")
    #   # => [{ "id" => 7, "name" => "Library Staff" }, ...]
    def self.groups(nuid)
      # user_details = login(nuid)
      # token = user_details[:token] ...
      # TODO - need to update atlas login to give back name, id, and token upon logging in
      # result = JSON.parse(connection({ token: token }).post('/users/2/groups')&.body)["user"]["groups"]
      read_body(connection({}, nuid).get('/user')) { |body| AtlasRb::Mash.new(body)["groups"] }
    end
  end
end
