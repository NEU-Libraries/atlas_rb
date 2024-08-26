# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "faraday/follow_redirects"
require_relative "atlas_rb/version"
require_relative "atlas_rb/faraday_helper"
require_relative "atlas_rb/resource"
require_relative "atlas_rb/community"
require_relative "atlas_rb/collection"
require_relative "atlas_rb/work"
require_relative "atlas_rb/file_set"
require_relative "atlas_rb/blob"

module AtlasRb
  class Error < StandardError; end
  # Your code goes here...
end
