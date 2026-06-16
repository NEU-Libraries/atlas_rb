# frozen_string_literal: true

require "tempfile"

# FileSet.update is the migration's ordered/classified-slot attach. These specs
# assert the binding shape without a round-trip: the multipart transport is
# stubbed to capture the payload + transport kwargs, and we capture the IO
# yielded into with_file_part to confirm it is closed deterministically (the
# FD-leak fix — with_file_part uses the block form of File.open).
RSpec.describe AtlasRb::FileSet do
  let(:tmp) do
    file = Tempfile.new(%w[page .tif])
    file.write("page-bytes")
    file.flush
    file
  end

  after { tmp.close! unless tmp.closed? }

  # Wrap the real (block-form) File.open so we can hold onto the yielded IO and
  # assert it was closed once the call returns.
  def capture_opened_io
    @opened = nil
    allow(File).to receive(:open).and_call_original
    allow(File).to(receive(:open).with(tmp.path, "rb").and_wrap_original do |orig, *args, &blk|
      orig.call(*args) do |io|
        @opened = io
        blk.call(io)
      end
    end)
  end

  # Stub `multipart` to return a connection double that records the patch payload.
  def stub_transport(expected_kwargs)
    @captured = nil
    conn = instance_double(Faraday::Connection)
    allow(conn).to receive(:patch) do |_route, payload|
      @captured = payload
      instance_double(Faraday::Response, body: '{"file_set":{"id":"fs-1"}}')
    end
    expect(described_class).to receive(:multipart).with(nil, **expected_kwargs).and_return(conn)
    capture_opened_io
  end

  describe ".update" do
    it "sends original_filename + expected_digest, idempotency_key to the transport, and closes the FD" do
      stub_transport(on_behalf_of: nil, idempotency_key: "key-1")

      described_class.update("fs-1", tmp.path,
                             original_filename: "page-0001.tif",
                             expected_digest: "sha256:abc",
                             idempotency_key: "key-1")

      expect(@captured[:original_filename]).to eq("page-0001.tif")
      expect(@captured[:expected_digest]).to eq("sha256:abc")
      expect(@captured[:binary]).to be_a(Faraday::Multipart::FilePart)
      expect(@opened).to be_closed
    end

    it "omits original_filename/expected_digest when not supplied" do
      stub_transport(on_behalf_of: nil, idempotency_key: nil)

      described_class.update("fs-1", tmp.path)

      expect(@captured).not_to have_key(:original_filename)
      expect(@captured).not_to have_key(:expected_digest)
      expect(@opened).to be_closed
    end

    it "closes the FD even when the request raises" do
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:patch).and_raise(AtlasRb::FixityMismatchError.new("nope", code: "fixity_mismatch"))
      allow(described_class).to receive(:multipart).and_return(conn)
      capture_opened_io

      expect { described_class.update("fs-1", tmp.path, expected_digest: "sha256:bad") }
        .to raise_error(AtlasRb::FixityMismatchError)
      expect(@opened).to be_closed
    end
  end
end
