# frozen_string_literal: true

# Transport auth-header behavior: relay-signing mode (the default — a signed
# ES256 assertion, no User header) versus BYO-JWT mode (ATLAS_JWT → bearer-only,
# no User / On-Behalf-Of). With neither configured the transport raises. We
# assert directly against the built Faraday connection's headers — no HTTP
# round-trip — since the gem's contract here is purely "which headers go out".
RSpec.describe AtlasRb::FaradayHelper do
  let(:host) { Class.new { extend AtlasRb::FaradayHelper } }

  around do |example|
    keys  = %w[ATLAS_URL ATLAS_JWT]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV["ATLAS_URL"] = "https://atlas.example.edu"
    ENV.delete("ATLAS_JWT")
    example.run
  ensure
    keys.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
  end

  describe "#connection" do
    context "BYO-JWT mode (ATLAS_JWT set)" do
      before { ENV["ATLAS_JWT"] = "jwt-abc" }

      it "uses the JWT as the bearer" do
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

    context "no auth configured (no ATLAS_JWT, no signing key)" do
      it "raises ConfigurationError" do
        expect { host.connection({}, "001234567") }
          .to raise_error(AtlasRb::ConfigurationError, /ATLAS_JWT or .*assertion_signing_key/)
      end
    end

    context "auth: :optional (for endpoints Atlas serves with require_auth skipped)" do
      it "sends no Authorization header instead of raising when nothing is configured" do
        headers = host.connection({}, auth: :optional).headers
        expect(headers).not_to have_key("Authorization")
        expect(headers).not_to have_key("User")
      end

      it "still signs when a signing key + acting nuid are available" do
        AtlasRb.config.assertion_signing_key = OpenSSL::PKey::EC.generate("prime256v1")
        AtlasRb.config.assertion_signing_kid = "k1"
        headers = host.connection({}, "001234567", auth: :optional).headers
        expect(headers["Authorization"]).to match(/\ABearer /)
      ensure
        AtlasRb.config.assertion_signing_key = nil
        AtlasRb.config.assertion_signing_kid = nil
      end
    end
  end

  describe "#system_connection" do
    let(:credentials) { double(atlas_system_token: "sys-token-abc") }
    let(:rails_app)   { double(credentials: credentials) }

    before { stub_const("Rails", double(application: rails_app)) }

    it "sends the hard-pinned system bearer + User header" do
      headers = host.system_connection.headers
      expect(headers["Authorization"]).to eq("Bearer sys-token-abc")
      expect(headers["User"]).to eq("NUID #{AtlasRb::System::NUID}")
    end

    it "omits On-Behalf-Of when not given" do
      expect(host.system_connection.headers).not_to have_key("On-Behalf-Of")
    end

    it "sends a plain On-Behalf-Of header when given (not a signed claim, unlike #connection)" do
      headers = host.system_connection({}, on_behalf_of: "001234567").headers
      expect(headers["On-Behalf-Of"]).to eq("NUID 001234567")
    end

    it "raises when the system token credential is not configured" do
      allow(credentials).to receive(:atlas_system_token).and_return(nil)
      expect { host.system_connection }.to raise_error(/atlas_system_token not configured/)
    end
  end

  describe "#multipart" do
    it "mirrors connection's mode selection in BYO-JWT mode" do
      ENV["ATLAS_JWT"] = "jwt-xyz"
      headers = host.multipart("001234567").headers
      expect(headers["Authorization"]).to eq("Bearer jwt-xyz")
      expect(headers).not_to have_key("User")
    end

    it "raises ConfigurationError when no auth is configured" do
      expect { host.multipart("001234567") }
        .to raise_error(AtlasRb::ConfigurationError)
    end
  end

  describe "relay-signing mode (config.assertion_signing_key set)" do
    let(:signing_key) { OpenSSL::PKey::EC.generate("prime256v1") }
    let(:kid)         { "cerberus-2026-06" }

    around do |example|
      saved_key = AtlasRb.config.assertion_signing_key
      saved_kid = AtlasRb.config.assertion_signing_kid
      AtlasRb.config.assertion_signing_key = signing_key
      AtlasRb.config.assertion_signing_kid = kid
      example.run
    ensure
      AtlasRb.config.assertion_signing_key = saved_key
      AtlasRb.config.assertion_signing_kid = saved_kid
    end

    # Decode the produced assertion with the public half — the exact shape Atlas
    # verifies (ES256, iss=cerberus, aud=atlas).
    def decode(token)
      pub = OpenSSL::PKey.read(signing_key.public_to_pem)
      JWT.decode(token, pub, true, algorithms: ["ES256"],
                 verify_iss: true, iss: "cerberus",
                 verify_aud: true, aud: "atlas")
    end

    def bearer(headers) = headers["Authorization"].sub(/\ABearer /, "")

    it "signs an assertion for the acting nuid, with no User header" do
      headers = host.connection({}, "001234567").headers
      expect(headers).not_to have_key("User")
      payload, header = decode(bearer(headers))
      expect(header["alg"]).to eq("ES256")
      expect(header["kid"]).to eq(kid)
      expect(payload).to include("iss" => "cerberus", "aud" => "atlas", "sub" => "001234567")
      expect(payload["exp"]).to be > Time.now.to_i
    end

    it "carries acting-as as a signed obo claim (operator=sub, target=obo), no header" do
      headers = host.connection({}, "001234567", on_behalf_of: "009999999").headers
      expect(headers).not_to have_key("User")
      expect(headers).not_to have_key("On-Behalf-Of")
      payload, = decode(bearer(headers))
      expect(payload).to include("sub" => "001234567", "obo" => "009999999")
    end

    it "omits the obo claim entirely for a non-acting-as request" do
      payload, = decode(bearer(host.connection({}, "001234567").headers))
      expect(payload).not_to have_key("obo")
    end

    it "carries the acting account as a signed acct claim when given" do
      headers = host.connection({}, "001234567", account: "j.doe@husky.neu.edu").headers
      payload, = decode(bearer(headers))
      expect(payload).to include("sub" => "001234567", "acct" => "j.doe@husky.neu.edu")
    end

    it "omits the acct claim entirely when no account is named" do
      payload, = decode(bearer(host.connection({}, "001234567").headers))
      expect(payload).not_to have_key("acct")
    end

    it "falls through to config.default_account when account: is omitted" do
      AtlasRb.config.default_account = -> { "ambient@husky.neu.edu" }
      payload, = decode(bearer(host.connection({}, "001234567").headers))
      expect(payload["acct"]).to eq("ambient@husky.neu.edu")
    ensure
      AtlasRb.config.default_account = nil
    end

    it "raises ConfigurationError when there is no acting nuid to sign for" do
      expect { host.connection({}) }.to raise_error(AtlasRb::ConfigurationError)
    end

    it "resolves a callable that returns a PEM string" do
      AtlasRb.config.assertion_signing_key = -> { signing_key.to_pem }
      payload, = decode(bearer(host.connection({}, "001234567").headers))
      expect(payload["sub"]).to eq("001234567")
    end

    it "lets ATLAS_JWT still win over signing" do
      ENV["ATLAS_JWT"] = "personal-jwt"
      headers = host.connection({}, "001234567").headers
      expect(headers["Authorization"]).to eq("Bearer personal-jwt")
      expect(headers).not_to have_key("User")
    ensure
      ENV.delete("ATLAS_JWT")
    end

    it "signs on the multipart transport too" do
      headers = host.multipart("001234567").headers
      expect(headers).not_to have_key("User")
      payload, = decode(bearer(headers))
      expect(payload["sub"]).to eq("001234567")
    end
  end
end
