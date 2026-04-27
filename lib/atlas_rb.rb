# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "faraday/follow_redirects"
require_relative "atlas_rb/version"
require_relative "atlas_rb/faraday_helper"
require_relative "atlas_rb/mash"
require_relative "atlas_rb/authentication"
require_relative "atlas_rb/resource"
require_relative "atlas_rb/community"
require_relative "atlas_rb/collection"
require_relative "atlas_rb/work"
require_relative "atlas_rb/file_set"
require_relative "atlas_rb/blob"

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
  # Generic error raised by future code paths; not currently used by any
  # resource class. Atlas errors today surface as raw `Faraday::Response`
  # objects or `JSON::ParserError`s on malformed bodies.
  class Error < StandardError; end

  # Test-environment helper that wipes Atlas state via `GET /reset`.
  #
  # **Do not call against production.** This exists so RSpec suites running
  # against a disposable Atlas instance can return to a clean baseline
  # between examples.
  class Reset
    extend AtlasRb::FaradayHelper

    # Reset the connected Atlas instance to a clean state.
    #
    # @return [String, nil] the raw response body from `GET /reset`.
    #
    # @example
    #   AtlasRb::Reset.clean
    def self.clean
      connection({}).get("/reset")&.body
    end
  end
end
