# frozen_string_literal: true

module AtlasRb
  module System
    # Personal-access token lifecycle — mint and revoke the 1-week JWT a real
    # person exports as `ATLAS_JWT` to drive atlas_rb / curl against Atlas
    # headless (BYO-JWT mode, see {AtlasRb::FaradayHelper}). Cerberus's "My DRS
    # → Programmatic access" section calls these post-SSO and hands the token
    # to the librarian; the token is never persisted by Cerberus.
    #
    # ## Why a separate class from {System::User}
    #
    # Token lifecycle is a distinct concern from SSO user provisioning: minting
    # a bearer credential for someone is "become anyone," which is exactly why
    # both Atlas endpoints are :system-gated (`authorize! :mint_token, User`).
    # Keeping it in its own class keeps that carve-out legible rather than
    # burying it among provisioning methods.
    #
    # Both methods authenticate via {FaradayHelper#system_connection} — the
    # hard-pinned system token + `User: NUID` header — so there is no way to
    # issue them as a regular user. This is never the ambient-user
    # relay-signing path.
    class Token
      extend AtlasRb::FaradayHelper

      # Mint a personal-access JWT for a real person (`POST /nuid`).
      # System-gated. The returned token authenticates as `nuid` in BYO-JWT
      # mode (Atlas resolves identity from the token's `sub`, ignores any
      # `User:` / `On-Behalf-Of` header, and refuses `:system`/`:anonymous`).
      # Full-privilege for that user, 1-week TTL, single-jti.
      #
      # @param nuid [String] the NUID the token will act as.
      # @return [String, nil] the JWT, or nil when the NUID has no Atlas User
      #   row (404) — a clean "no such user" signal for the caller to surface.
      def self.mint(nuid:)
        response = system_connection.post("/nuid", { nuid: nuid }.to_json)
        return nil if response.status == 404

        AtlasRb::Mash.new(JSON.parse(response.body))["token"]
      end

      # Revoke every outstanding token for a user (`DELETE /nuid`) by rotating
      # its jti. System-gated. Single-jti model → all-or-nothing: every token
      # the user holds dies at once. "Regenerate" on the Cerberus side is
      # {.revoke} followed by a fresh {.mint}.
      #
      # The NUID rides as a query param (`system_connection`'s params hash) so
      # this sidesteps DELETE-with-body handling; Atlas reads it from
      # `params[:nuid]` either way.
      #
      # @param nuid [String] the NUID whose tokens to invalidate.
      # @return [Boolean] true on success (204), false when the NUID has no
      #   Atlas User row (404).
      def self.revoke(nuid:)
        system_connection({ nuid: nuid }).delete("/nuid").status == 204
      end
    end
  end
end
