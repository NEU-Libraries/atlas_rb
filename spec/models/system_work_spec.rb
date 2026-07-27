# frozen_string_literal: true

# Binding shape for the showcase-publishing endpoint, asserted without a
# round-trip (the transport is stubbed to capture route + payload) — mirrors
# the account-switching bindings spec's approach.
RSpec.describe AtlasRb::System::Work do
  describe ".add_linked_member" do
    it "POSTs to /works/:id/linked_members with collection_id, forwarding on_behalf_of to system_connection" do
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:post).with("/works/w-1/linked_members")
                                   .and_return(instance_double(Faraday::Response, body: '["col-456"]'))
      expect(described_class).to receive(:system_connection)
        .with({ collection_id: "col-456" }, on_behalf_of: "001234567")
        .and_return(conn)

      result = described_class.add_linked_member("w-1", "col-456", on_behalf_of: "001234567")
      expect(result).to eq(["col-456"])
    end
  end
end
