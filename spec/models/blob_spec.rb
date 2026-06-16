# frozen_string_literal: true

require "tempfile"

# Blob.create / Blob.update binding shape, asserted without a round-trip (the
# multipart transport is stubbed to capture the payload). Confirms expected_digest
# threads through and the upload IO (yielded into with_file_part's block-form
# File.open) is closed deterministically.
RSpec.describe AtlasRb::Blob do
  let(:tmp) do
    file = Tempfile.new(%w[upload .bin])
    file.write("blob-bytes")
    file.flush
    file
  end

  after { tmp.close! unless tmp.closed? }

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

  def stub_post(expected_kwargs)
    @captured = nil
    conn = instance_double(Faraday::Connection)
    allow(conn).to receive(:post) do |_route, payload|
      @captured = payload
      instance_double(Faraday::Response, body: '{"blob":{"id":"b-1","digest":"sha512:ff"}}')
    end
    expect(described_class).to receive(:multipart).with(nil, **expected_kwargs).and_return(conn)
    capture_opened_io
  end

  describe ".create" do
    it "sends work_id, original_filename, and expected_digest, and closes the FD" do
      stub_post(on_behalf_of: nil, idempotency_key: "k-1")

      result = described_class.create("w-1", tmp.path, "thesis.pdf",
                                      expected_digest: "sha256:abc", idempotency_key: "k-1")

      expect(@captured[:work_id]).to eq("w-1")
      expect(@captured[:original_filename]).to eq("thesis.pdf")
      expect(@captured[:expected_digest]).to eq("sha256:abc")
      expect(@captured[:binary]).to be_a(Faraday::Multipart::FilePart)
      expect(@opened).to be_closed
      expect(result["digest"]).to eq("sha512:ff")
    end

    it "omits expected_digest when not supplied" do
      stub_post(on_behalf_of: nil, idempotency_key: nil)

      described_class.create("w-1", tmp.path, "thesis.pdf")

      expect(@captured).not_to have_key(:expected_digest)
      expect(@opened).to be_closed
    end
  end
end
