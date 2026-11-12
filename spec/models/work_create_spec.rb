# frozen_string_literal: true

# The params Work.create builds, with the transport stubbed. A `handle:` must
# reach Atlas only when the caller passes one: an empty `handle` param is a
# 422 from Atlas, and a nil one would be an identity claim nobody made.
RSpec.describe AtlasRb::Work do
  def stub_transport
    @params = nil
    conn = instance_double(Faraday::Connection)
    allow(conn).to receive(:post) do
      instance_double(Faraday::Response, status: 200, success?: true,
                                         body: '{"work":{"id":"w-1","handle":"2047/d20001234"}}')
    end
    allow(described_class).to receive(:connection) do |params, _nuid, **_kwargs|
      @params = params
      conn
    end
  end

  describe ".create" do
    it "sends a supplied handle beside the parent" do
      stub_transport

      result = described_class.create("col-456", handle: "2047/d20001234")

      expect(@params).to eq(collection_id: "col-456", handle: "2047/d20001234")
      expect(result["handle"]).to eq("2047/d20001234")
    end

    it "sends no handle param when none is given" do
      stub_transport

      described_class.create("col-456", depositor: "000000123")

      expect(@params).to eq(collection_id: "col-456", depositor: "000000123")
    end
  end
end
