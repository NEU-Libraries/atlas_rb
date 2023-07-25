# frozen_string_literal: true

require 'atlas_rb/faraday_helper'
include AtlasRb::FaradayHelper

RSpec.describe AtlasRb do
  it "has a version number" do
    expect(AtlasRb::VERSION).not_to be nil
  end

  it "does something useful" do
    response = connection({param: '1'}).post('/post') do |req|
      req.params['limit'] = 100
      req.body = {query: 'chunky bacon'}.to_json
    end
    expect(response).to be_a Faraday::Response
  end
end
