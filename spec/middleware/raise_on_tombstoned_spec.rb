# frozen_string_literal: true

# A 410 means two different things on the wire. With Atlas's tombstone envelope
# it is a refusal and must raise; with a resource's own body it is the answer a
# find returns. Driven through Faraday's test adapter.
RSpec.describe AtlasRb::Middleware::RaiseOnTombstoned do
  def connection(&stub_block)
    Faraday.new do |f|
      f.use AtlasRb::Middleware::RaiseOnReadError
      f.use described_class
      f.adapter :test, &stub_block
    end
  end

  let(:envelope) do
    '{"error":"tombstoned","resource_id":"w-1","tombstoned_resource_id":"fs-2",' \
      '"tombstoned_resource_type":"FileSet","message":"fileset fs-2 is tombstoned"}'
  end

  it "raises TombstonedError on a 410 carrying the discriminator" do
    conn = connection { |s| s.get("/works/w-1/assets") { [410, {}, envelope] } }

    expect { conn.get("/works/w-1/assets") }.to raise_error(AtlasRb::TombstonedError) do |e|
      expect(e.message).to eq("fileset fs-2 is tombstoned")
      expect(e.tombstoned_resource_id).to eq("fs-2")
      expect(e.tombstoned_resource_type).to eq("FileSet")
      expect(e.work_retracted?).to be(false)
      expect(e.status).to eq(410)
    end
  end

  it "passes a 410 carrying the resource's own body through, as a find returns it" do
    body = '{"work":{"id":"w-1","tombstoned":true}}'
    conn = connection { |s| s.get("/works/w-1") { [410, {}, body] } }

    expect(conn.get("/works/w-1").body).to eq(body)
  end

  it "passes a bodyless 410 through" do
    conn = connection { |s| s.get("/works/w-1") { [410, {}, ""] } }

    expect(conn.get("/works/w-1").status).to eq(410)
  end
end
