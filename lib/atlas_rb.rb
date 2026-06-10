# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "faraday/follow_redirects"
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
require_relative "atlas_rb/user"
require_relative "atlas_rb/admin"
require_relative "atlas_rb/admin/work"
require_relative "atlas_rb/admin/collection"
require_relative "atlas_rb/admin/community"
require_relative "atlas_rb/system/user"
require_relative "atlas_rb/audit_event"

# Ruby client for the Atlas API — Northeastern University's institutional
# digital repository.
#
# ## Configuration
#
# Two environment variables drive every request:
#
# - `ATLAS_URL`   — base URL of the Atlas API (e.g. `https://atlas.example.edu`).
# - `ATLAS_TOKEN` — bearer token sent in the `Authorization` header.
#
# {AtlasRb::Authentication} additionally accepts an NUID (Northeastern
# University ID) which is forwarded in a `User: NUID <nuid>` header so the
# server can resolve the acting user.
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
#   ENV["ATLAS_URL"]   = "https://atlas.example.edu"
#   ENV["ATLAS_TOKEN"] = "..."
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
    # @param nuid [String, nil] optional acting user's NUID, forwarded as the
    #   `User:` header. Required for cerberus-token requests; legacy bearer
    #   tokens still resolve without it. Atlas's `MaintenanceController#reset`
    #   runs through the standard `require_auth` filter, so under Atlas
    #   0.6.12+ the header is needed for any cerberus-token caller.
    # @param on_behalf_of [String, nil] optional NUID for the `On-Behalf-Of`
    #   header. Falls through to {AtlasRb.config}.default_on_behalf_of when
    #   omitted.
    # @return [String, nil] the raw response body from `GET /reset`.
    #
    # @example
    #   AtlasRb::Reset.clean(nuid: "000000000")
    def self.clean(nuid: nil, on_behalf_of: nil)
      connection({}, nuid, on_behalf_of: on_behalf_of).get("/reset")&.body
    end
  end
end
