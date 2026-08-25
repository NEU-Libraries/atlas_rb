# frozen_string_literal: true

# The maintenance window is a new wire signal the gem has to learn, so it gets
# its own spec rather than riding on a binding's. Two properties matter and are
# in tension: a 503 carrying Atlas's discriminator must raise on ANY path, and a
# bodyless 503 (a reverse proxy while Atlas restarts) must still pass through as
# it did before this middleware existed. Driven through Faraday's test adapter.
RSpec.describe AtlasRb::Middleware::RaiseOnReadOnlyMode do
  def connection(&stub_block)
    Faraday.new do |f|
      f.use described_class
      f.adapter :test, &stub_block
    end
  end

  ENVELOPE = '{"error":"read_only_mode","message":"Atlas is in maintenance mode; writes are refused"}'

  it "raises ReadOnlyModeError on a 503 carrying the discriminator" do
    conn = connection do |s|
      s.patch("/works/w-1") { [503, { "Retry-After" => "900" }, ENVELOPE] }
    end

    expect { conn.patch("/works/w-1") }.to raise_error(AtlasRb::ReadOnlyModeError) do |e|
      expect(e.code).to eq("read_only_mode")
      expect(e.retry_after).to eq(900)
      expect(e.message).to eq("Atlas is in maintenance mode; writes are refused")
    end
  end

  # Path-independence is the point: a window refuses writes everywhere, so a
  # path-keyed rule would have to enumerate the whole write surface.
  it "raises on any path, not an enumerated write surface" do
    %w[/files/ /compilations /users/by_email/a@b.edu /some/endpoint/added/next/year].each do |path|
      conn = connection { |s| s.post(path) { [503, {}, ENVELOPE] } }
      expect { conn.post(path) }.to raise_error(AtlasRb::ReadOnlyModeError)
    end
  end

  it "passes a bodyless 503 through untouched, as a restarting proxy sends" do
    conn = connection { |s| s.patch("/works/w-1") { [503, {}, ""] } }
    expect(conn.patch("/works/w-1").status).to eq(503)
  end

  it "passes a 503 with a different discriminator through untouched" do
    conn = connection { |s| s.patch("/works/w-1") { [503, {}, '{"error":"upstream_timeout"}'] } }
    expect(conn.patch("/works/w-1").status).to eq(503)
  end

  it "leaves every other status alone" do
    [200, 403, 409, 422, 500].each do |status|
      conn = connection { |s| s.patch("/works/w-1") { [status, {}, ENVELOPE] } }
      expect(conn.patch("/works/w-1").status).to eq(status)
    end
  end

  it "tolerates a missing Retry-After header" do
    conn = connection { |s| s.patch("/works/w-1") { [503, {}, ENVELOPE] } }
    expect { conn.patch("/works/w-1") }
      .to raise_error(AtlasRb::ReadOnlyModeError) { |e| expect(e.retry_after).to be_nil }
  end

  # A 503 previously reached neither RaiseOnStaleResource (409-only) nor
  # RaiseOnResourceError (403/422-only), so the binding unwrapped a nil body and
  # returned it: the write no-opped and the UI reported success.
  # FaradayHelper builds three connections and registers middleware separately
  # in each, so adding this to one is the likely mistake. Missing it on any
  # builder restores the silent no-op for every binding on that transport.
  it "is registered on all three connection builders" do
    helper = Class.new { extend AtlasRb::FaradayHelper }
    ENV["ATLAS_JWT"] = "jwt-for-builder-check"
    credentials = double(atlas_system_token: "system-token-for-builder-check")
    stub_const("Rails", double(application: double(credentials: credentials)))

    connections = [helper.connection({}), helper.multipart, helper.system_connection]

    connections.each { |conn| expect(conn.builder.handlers).to include(described_class) }
  ensure
    ENV.delete("ATLAS_JWT")
  end
end
