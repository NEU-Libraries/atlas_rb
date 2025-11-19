# frozen_string_literal: true

module AtlasRb
  class Authentication
    extend AtlasRb::FaradayHelper

    def self.login(nuid)
      # JSON.parse(connection({ nuid: nuid }).post('/token')&.body)["token"]
      # need hash - id, name, token => ...
      JSON.parse(connection({}, nuid).get('/user')&.body)
    end

    def self.groups(nuid)
      # user_details = login(nuid)
      # token = user_details[:token] ...
      # TODO - need to update atlas login to give back name, id, and token upon logging in
      # result = JSON.parse(connection({ token: token }).post('/users/2/groups')&.body)["user"]["groups"]
      JSON.parse(connection({}, nuid).get('/user')&.body)["groups"]
    end
  end
end
