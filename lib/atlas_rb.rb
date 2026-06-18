# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "faraday/follow_redirects"
require "jwt"
require "openssl"
require "securerandom"
require_relative "atlas_rb/version"
require_relative "atlas_rb/errors"
require_relative "atlas_rb/configuration"
require_relative "atlas_rb/middleware/raise_on_stale_resource"
require_relative "atlas_rb/middleware/raise_on_resource_error"
require_relative "atlas_rb/faraday_helper"
require_relative "atlas_rb/mash"
require_relative "atlas_rb/authentication"
require_relative "atlas_rb/resource"
require_relative "atlas_rb/community"
require_relative "atlas_rb/collection"
require_relative "atlas_rb/work"
require_relative "atlas_rb/file_set"
require_relative "atlas_rb/blob"
require_relative "atlas_rb/delegate"
require_relative "atlas_rb/compilation"
require_relative "atlas_rb/person"
require_relative "atlas_rb/user"
require_relative "atlas_rb/admin"
require_relative "atlas_rb/admin/work"
require_relative "atlas_rb/admin/collection"
require_relative "atlas_rb/admin/community"
require_relative "atlas_rb/system"
require_relative "atlas_rb/system/user"
require_relative "atlas_rb/audit_event"

# Ruby client for the Atlas API — Northeastern University's institutional
# digital repository.
#
# ## Configuration
#
# Environment variables drive every request:
#
# - `ATLAS_URL`   — base URL of the Atlas API (e.g. `https://atlas.example.edu`).
# - `ATLAS_JWT`   — optional personal-access JWT (minted by Atlas's
#   `POST /nuid`). When set, the transport runs in bring-your-own-JWT mode:
#   the JWT is the bearer and no `User:` / `On-Behalf-Of:` headers are sent.
#   See {AtlasRb::FaradayHelper} for the mode semantics.
#
# The default (relay) path signs a short-lived ES256 assertion for the acting
# NUID with Cerberus's private key, configured via
# {AtlasRb.config#assertion_signing_key} / `assertion_signing_kid`. Identity is
# the signed `sub`; see {AtlasRb::FaradayHelper}.
#
# ## Resource hierarchy
#
#     {AtlasRb::Community}  →  {AtlasRb::Collection}  →  {AtlasRb::Work}
#                                                          ↓
#                                                       {AtlasRb::FileSet}
#                                                          ↓
#                                                       {AtlasRb::Blob}
#
# - **Community** — top-level org unit; may nest sub-Communities.
# - **Collection** — holds Works; lives directly under a Community.
# - **Work** — the bibliographic unit (article, thesis, dataset…); MODS
#   metadata is attached here.
# - **FileSet** — classified slot under a Work that owns one Blob.
# - **Blob** — the binary bytes themselves; supports streaming downloads
#   via {AtlasRb::Blob.content}.
#
# ## Quick start
#
# @example End-to-end: create a Work and attach a file
#   ENV["ATLAS_URL"] = "https://atlas.example.edu"
#   # plus a configured signing key (relay) or ENV["ATLAS_JWT"] (BYO-JWT)
#
#   community  = AtlasRb::Community.create(nil, "/tmp/community-mods.xml")
#   collection = AtlasRb::Collection.create(community["id"], "/tmp/coll-mods.xml")
#   work       = AtlasRb::Work.create(collection["id"], "/tmp/work-mods.xml")
#   blob       = AtlasRb::Blob.create(work["id"],
#                                     "/tmp/upload.tmp",
#                                     "thesis.pdf")
#
# @example Streaming a download
#   File.open("out.pdf", "wb") do |f|
#     AtlasRb::Blob.content(blob["id"]) { |chunk| f.write(chunk) }
#   end
module AtlasRb
  # The error hierarchy ({AtlasRb::Error}, {AtlasRb::StaleResourceError}) lives
  # in `atlas_rb/errors.rb`, required above.

  # The gem-wide configuration instance. Lazily initialized — host
  # applications register defaults via {AtlasRb.configure}.
  #
  # @return [AtlasRb::Configuration] the singleton configuration.
  def self.config
    @config ||= Configuration.new
  end

  # Yield the configuration for registration.
  #
  # When `default_nuid` or `default_on_behalf_of` are set, resource methods
  # that take `nuid:` / `on_behalf_of:` kwargs will fall through to the
  # registered callables whenever the caller omits the kwarg (or passes
  # `nil`). Caller-passed values always win.
  #
  # @yieldparam config [AtlasRb::Configuration] the configuration to mutate.
  # @return [AtlasRb::Configuration] the configured instance.
  #
  # @example Registering an ambient NUID source in a Rails initializer
  #   AtlasRb.configure do |config|
  #     config.default_nuid         = -> { Current.nuid }
  #     config.default_on_behalf_of = -> { Current.on_behalf_of }
  #   end
  def self.configure
    yield config
    config
  end

  # Test-environment helper that wipes Atlas state via `GET /reset`.
  #
  # **Do not call against production.** This exists so RSpec suites running
  # against a disposable Atlas instance can return to a clean baseline
  # between examples.
  class Reset
    extend AtlasRb::FaradayHelper

    # Reset the connected Atlas instance to a clean state.
    #
    # Atlas serves `GET /reset` with `require_auth` **skipped** (it is env-gated,
    # not principal-gated), so this call uses **optional auth**: it signs an
    # assertion when a credential is available, and sends no `Authorization`
    # header otherwise — never raising {AtlasRb::ConfigurationError} for lack of
    # one. That lets a test `before(:suite)` reset before any acting nuid is set.
    #
    # @param nuid [String, nil] optional acting user's NUID. When a signing key
    #   is configured it is signed into the assertion `sub`; otherwise it is
    #   unused (Atlas ignores it on this endpoint). Mostly here for symmetry.
    # @param on_behalf_of [String, nil] optional NUID. Falls through to
    #   {AtlasRb.config}.default_on_behalf_of when omitted.
    # @return [String, nil] the raw response body from `GET /reset`.
    #
    # @example
    #   AtlasRb::Reset.clean
    def self.clean(nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of, auth: :optional).get("/reset")&.body
    end
  end
end
