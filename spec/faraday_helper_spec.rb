# frozen_string_literal: true

# Transport auth-header behavior: the relay path (ATLAS_TOKEN + User header)
# versus BYO-JWT mode (ATLAS_JWT → bearer-only, no User / On-Behalf-Of). We
# assert directly against the built Faraday connection's headers — no HTTP
# round-trip — since the gem's contract here is purely "which headers go out".
RSpec.describe AtlasRb::FaradayHelper do
  let(:host) { Class.new { extend AtlasRb::FaradayHelper } }

  around do |example|
    keys  = %w[ATLAS_URL ATLAS_TOKEN ATLAS_JWT]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV["ATLAS_URL"] = "https://atlas.example.edu"
    ENV.delete("ATLAS_TOKEN")
    ENV.delete("ATLAS_JWT")
    example.run
  ensure
    keys.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
  end

  describe "#connection" do
    context "relay mode (ATLAS_TOKEN, no ATLAS_JWT)" do
      before { ENV["ATLAS_TOKEN"] = "relay-token" }

      it "uses ATLAS_TOKEN as the bearer and names the acting user" do
        headers = host.connection({}, "001234567").headers
        expect(headers["Authorization"]).to eq("Bearer relay-token")
        expect(headers["User"]).to eq("NUID 001234567")
      end

      it "sends On-Behalf-Of when provided" do
        headers = host.connection({}, "001234567", on_behalf_of: "009999999").headers
        expect(headers["On-Behalf-Of"]).to eq("NUID 009999999")
      end
    end

    context "BYO-JWT mode (ATLAS_JWT set)" do
      before do
        ENV["ATLAS_JWT"]   = "jwt-abc"
        ENV["ATLAS_TOKEN"] = "relay-token" # JWT must win
      end

      it "uses the JWT as the bearer, taking precedence over ATLAS_TOKEN" do
        expect(host.connection({}).headers["Authorization"]).to eq("Bearer jwt-abc")
      end

      it "omits the User header even when an nuid is passed (identity is in the token)" do
        expect(host.connection({}, "001234567").headers).not_to have_key("User")
      end

      it "suppresses On-Behalf-Of (acting-as is forbidden on the JWT path)" do
        headers = host.connection({}, "001234567", on_behalf_of: "009999999").headers
        expect(headers).not_to have_key("On-Behalf-Of")
      end
    end
  end

  describe "#multipart" do
    it "mirrors connection's mode selection in BYO-JWT mode" do
      ENV["ATLAS_JWT"] = "jwt-xyz"
      headers = host.multipart("001234567").headers
      expect(headers["Authorization"]).to eq("Bearer jwt-xyz")
      expect(headers).not_to have_key("User")
    end

    it "uses ATLAS_TOKEN and the User header in relay mode" do
      ENV["ATLAS_TOKEN"] = "relay-token"
      headers = host.multipart("001234567").headers
      expect(headers["Authorization"]).to eq("Bearer relay-token")
      expect(headers["User"]).to eq("NUID 001234567")
    end
  end
end
