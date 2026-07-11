# frozen_string_literal: true

# Binding shapes for the account-switching endpoints, asserted without a
# round-trip (the transport is stubbed to capture route + payload). Confirms
# each method targets the right Atlas endpoint keyed on the right identifier.
RSpec.describe "account-switching bindings" do
  describe AtlasRb::System::User do
    describe ".find_or_create" do
      it "PUTs to /users/by_email/:email keyed on email, with nuid/groups/name/affiliation" do
        captured = nil
        conn = instance_double(Faraday::Connection)
        allow(conn).to receive(:put) do |route, body|
          captured = [route, JSON.parse(body)]
          instance_double(Faraday::Response, body: '{"user":{"id":1,"email":"j@x.edu","nuid":"001"}}')
        end
        allow(described_class).to receive(:system_connection).and_return(conn)

        result = described_class.find_or_create(email: "j@x.edu", nuid: "001",
                                                groups: ["g:staff"], name: "Jane", affiliation: "staff")

        expect(captured[0]).to eq("/users/by_email/j@x.edu")
        expect(captured[1]).to eq("groups" => ["g:staff"], "nuid" => "001",
                                  "name" => "Jane", "affiliation" => "staff")
        expect(result["email"]).to eq("j@x.edu")
      end
    end
  end

  describe AtlasRb::User do
    describe ".accounts" do
      it "GETs /users/by_nuid/:nuid/accounts and returns the envelope" do
        conn = instance_double(Faraday::Connection)
        allow(conn).to receive(:get).with("/users/by_nuid/001/accounts")
          .and_return(instance_double(Faraday::Response,
                                      body: '{"nuid":"001","accounts":[{"email":"a@x.edu","preferred":true}]}'))
        allow(described_class).to receive(:connection).with({}, "001").and_return(conn)

        result = described_class.accounts("001", nuid: "001")
        expect(result["nuid"]).to eq("001")
        expect(result["accounts"].first["email"]).to eq("a@x.edu")
        expect(result["accounts"].first["preferred"]).to be(true)
      end
    end

    describe ".set_preferred" do
      it "PUTs the email to /users/by_nuid/:nuid/preferred_account" do
        captured = nil
        conn = instance_double(Faraday::Connection)
        allow(conn).to receive(:put) do |route, body|
          captured = [route, JSON.parse(body)]
          instance_double(Faraday::Response, body: '{"user":{"email":"b@x.edu","preferred":true}}')
        end
        allow(described_class).to receive(:connection).with({}, "001").and_return(conn)

        result = described_class.set_preferred("001", email: "b@x.edu", nuid: "001")
        expect(captured[0]).to eq("/users/by_nuid/001/preferred_account")
        expect(captured[1]).to eq("email" => "b@x.edu")
        expect(result["preferred"]).to be(true)
      end
    end
  end

  describe AtlasRb::Authentication do
    describe ".login" do
      it "threads the email through as the signed account selector" do
        conn = instance_double(Faraday::Connection)
        allow(conn).to receive(:get).with("/user")
          .and_return(instance_double(Faraday::Response, body: '{"id":1,"email":"b@x.edu","groups":["g"]}'))
        expect(described_class).to receive(:connection).with({}, "001", account: "b@x.edu").and_return(conn)

        result = described_class.login("001", email: "b@x.edu")
        expect(result["email"]).to eq("b@x.edu")
      end
    end
  end
end
