# frozen_string_literal: true

# Binding shapes for the maintenance-window endpoints, asserted without a
# round-trip (the transport is stubbed to capture route + payload).
RSpec.describe AtlasRb::Maintenance do
  describe ".read" do
    # GET sits on Atlas's authenticated read floor, not the system connection:
    # a client that could not read the flag could not honour it, so the read has
    # to work for the same principals the window is refusing writes to.
    it "GETs /maintenance over the ordinary connection" do
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:get).with("/maintenance")
        .and_return(instance_double(Faraday::Response,
                                    body: '{"read_only":true,"source":"deploy",' \
                                          '"since":"2026-08-25T09:14:00Z",' \
                                          '"message":"Scheduled maintenance until 10:00",' \
                                          '"retry_after":900}'))
      allow(described_class).to receive(:connection).with({}).and_return(conn)

      result = described_class.read

      expect(result["read_only"]).to be(true)
      expect(result["source"]).to eq("deploy")
      expect(result["retry_after"]).to eq(900)
      expect(result["message"]).to eq("Scheduled maintenance until 10:00")
    end
  end

  describe ".write" do
    def stub_put(response_body)
      captured = []
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:put) do |route, body|
        captured = [route, JSON.parse(body)]
        instance_double(Faraday::Response, body: response_body)
      end
      allow(described_class).to receive(:system_connection).and_return(conn)
      captured_ref = -> { captured }
      [conn, captured_ref]
    end

    it "PUTs /maintenance over the system connection, since the flip is system-gated" do
      _conn, captured = stub_put('{"read_only":true,"source":"operator","since":"2026-08-25T09:14:00Z",' \
                                 '"message":"Back at 10:00","retry_after":900}')

      result = described_class.write(read_only: true, source: "operator", message: "Back at 10:00")

      expect(captured.call[0]).to eq("/maintenance")
      expect(captured.call[1]).to eq("read_only" => true, "source" => "operator",
                                     "message" => "Back at 10:00")
      expect(result["read_only"]).to be(true)
    end

    it "omits message and retry_after when not given, rather than sending nulls" do
      _conn, captured = stub_put('{"read_only":false,"source":null,"since":null,' \
                                 '"message":null,"retry_after":900}')

      described_class.write(read_only: false, source: "deploy")

      expect(captured.call[1]).to eq("read_only" => false, "source" => "deploy")
    end

    # Atlas refuses a deploy's close of an operator-opened window by answering
    # 200 with the UNCHANGED state, not an error — so the caller must read
    # read_only off the return value rather than assume the write took.
    it "returns the unchanged state when Atlas refuses a deploy's close" do
      stub_put('{"read_only":true,"source":"operator","since":"2026-08-25T09:14:00Z",' \
               '"message":null,"retry_after":900}')

      result = described_class.write(read_only: false, source: "deploy")

      expect(result["read_only"]).to be(true)
      expect(result["source"]).to eq("operator")
    end
  end
end
