# frozen_string_literal: true

module AtlasRb
  class Authentication
    extend AtlasRb::FaradayHelper

    def self.login(nuid)
      JSON.parse(connection({ nuid: nuid }).post('/token')&.body)["token"]
    end

    def self.groups(nuid)
      token = login(nuid)
      # TODO
    end
  end
end
