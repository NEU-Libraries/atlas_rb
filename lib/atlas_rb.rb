# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require_relative "atlas_rb/version"
require_relative "atlas_rb/faraday_helper"
require_relative "atlas_rb/resource"
require_relative "atlas_rb/community"

module AtlasRb
  class Error < StandardError; end
  # Your code goes here...
end
