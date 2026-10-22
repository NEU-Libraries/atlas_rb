# frozen_string_literal: true

# Same two properties as the maintenance middleware: Atlas's discriminator
# raises on any path, and a bodyless 503 from a proxy still passes through.
RSpec.describe AtlasRb::Middleware::RaiseOnBackendUnavailable do
  def connection(&stub_block)
    Faraday.new do |f|
      f.use described_class
      f.adapter :test, &stub_block
    end
  end

  let(:envelope) do
    { error: "backend_unavailable", dependency: "storage",
      message: "Atlas cannot reach its storage; try again shortly" }.to_json
  end

  it "raises BackendUnavailableError on a 503 carrying the discriminator" do
    conn = connection { |s| s.get("/files/b-1/content") { [503, { "Retry-After" => "30" }, envelope] } }

    expect { conn.get("/files/b-1/content") }.to raise_error(AtlasRb::BackendUnavailableError) do |e|
      expect(e.code).to eq("backend_unavailable")
      expect(e.dependency).to eq("storage")
      expect(e.retry_after).to eq(30)
      expect(e.message).to eq("Atlas cannot reach its storage; try again shortly")
    end
  end

  it "is not a ResourceError, which hosts treat as a refusal" do
    expect(AtlasRb::BackendUnavailableError.ancestors).not_to include(AtlasRb::ResourceError)
  end

  it "passes a bodyless 503 through untouched, as a restarting proxy sends" do
    conn = connection { |s| s.get("/works/w-1") { [503, {}, ""] } }
    expect(conn.get("/works/w-1").status).to eq(503)
  end

  it "leaves the maintenance 503 to its own middleware" do
    conn = connection { |s| s.patch("/works/w-1") { [503, {}, '{"error":"read_only_mode"}'] } }
    expect(conn.patch("/works/w-1").status).to eq(503)
  end

  # On the real stack the read guard runs after this one; were the order
  # reversed, an outage on a read would surface as a generic ResourceError.
  it "wins over the read guard on the shared stack" do
    stubs = Faraday::Adapter::Test::Stubs.new { |s| s.get("/works/w-1") { [503, {}, envelope] } }
    conn = Faraday.new do |f|
      AtlasRb::Work.send(:error_middleware, f, reads: true)
      f.adapter :test, stubs
    end

    expect { conn.get("/works/w-1") }.to raise_error(AtlasRb::BackendUnavailableError)
  end
end
