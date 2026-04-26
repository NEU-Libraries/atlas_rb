# frozen_string_literal: true

module AtlasRb
  # User-facing identity lookups against the Atlas API.
  #
  # Unlike the resource classes, {Authentication} threads a real NUID into the
  # `User` header via {FaradayHelper#connection}'s second positional argument.
  # The Atlas server uses that NUID — combined with the bearer token from
  # `ATLAS_TOKEN` — to resolve the acting user and their group memberships.
  #
  # No login round-trip happens here today; the bearer token is assumed to be
  # already provisioned out-of-band. The commented-out code in this file
  # reflects an older flow where a `/token` endpoint exchanged an NUID for a
  # session token.
  class Authentication
    extend AtlasRb::FaradayHelper

    # Look up the Atlas user record for an NUID.
    #
    # @param nuid [String] the user's Northeastern University ID.
    # @return [Hash] the user record returned by `GET /user`, including at
    #   minimum `"id"`, `"name"`, and `"groups"`.
    # @raise [JSON::ParserError] if the response body is not valid JSON
    #   (typically caused by an auth failure returning HTML).
    #
    # @example
    #   AtlasRb::Authentication.login("001234567")
    #   # => { "id" => 42, "name" => "Jane Doe", "groups" => [...] }
    def self.login(nuid)
      # JSON.parse(connection({ nuid: nuid }).post('/token')&.body)["token"]
      # need hash - id, name, token => ...
      JSON.parse(connection({}, nuid).get('/user')&.body)
    end

    # Fetch only the group memberships for an NUID.
    #
    # Convenience wrapper around the same `GET /user` call as {.login}; useful
    # when authorization checks only need group names.
    #
    # @param nuid [String] the user's Northeastern University ID.
    # @return [Array<Hash>] the `"groups"` array from the user record.
    # @raise [JSON::ParserError] if the response body is not valid JSON.
    #
    # @example
    #   AtlasRb::Authentication.groups("001234567")
    #   # => [{ "id" => 7, "name" => "Library Staff" }, ...]
    def self.groups(nuid)
      # user_details = login(nuid)
      # token = user_details[:token] ...
      # TODO - need to update atlas login to give back name, id, and token upon logging in
      # result = JSON.parse(connection({ token: token }).post('/users/2/groups')&.body)["user"]["groups"]
      JSON.parse(connection({}, nuid).get('/user')&.body)["groups"]
    end
  end
end
