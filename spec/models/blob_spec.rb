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

  describe ".update" do
    def stub_patch(expected_kwargs)
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:patch).and_return(
        instance_double(Faraday::Response, body: '{"blob":{"id":"b-1","digest":"sha512:ff"}}')
      )
      expect(described_class).to receive(:multipart).with(nil, **expected_kwargs).and_return(conn)
      capture_opened_io
    end

    it "threads idempotency_key through to multipart (replay-safe replace)" do
      stub_patch(on_behalf_of: nil, idempotency_key: "k-9")

      described_class.update("b-1", tmp.path, idempotency_key: "k-9")

      expect(@opened).to be_closed
    end

    it "omits the key when not supplied" do
      stub_patch(on_behalf_of: nil, idempotency_key: nil)

      described_class.update("b-1", tmp.path)

      expect(@opened).to be_closed
    end
  end

  # The version read surface: thin Faraday wrappers, asserted on URL shape and
  # return unwrapping without a round-trip (the JSON connection is stubbed).
  describe "version read surface" do
    def stub_connection
      conn = instance_double(Faraday::Connection)
      expect(described_class).to receive(:connection)
        .with({}, nil, on_behalf_of: nil).and_return(conn)
      conn
    end

    describe ".versions" do
      it "GETs /files/:id/versions and returns the envelope unwrapped" do
        conn = stub_connection
        expect(conn).to receive(:get).with("/files/b-1/versions").and_return(
          instance_double(Faraday::Response,
                          body: '{"blob_id":"b-1","versions":[{"version_id":"v5","digest":"sha512:ff"}]}')
        )

        envelope = described_class.versions("b-1")
        expect(envelope["blob_id"]).to eq("b-1")
        expect(envelope["versions"].first["version_id"]).to eq("v5")
      end
    end

    describe ".rollback" do
      it "POSTs the version_id and returns the updated blob unwrapped" do
        conn = stub_connection
        expect(conn).to receive(:post)
          .with("/files/b-1/rollback", JSON.dump(version_id: "v1"))
          .and_return(instance_double(Faraday::Response, body: '{"blob":{"id":"b-1","digest":"sha512:aa"}}'))

        blob = described_class.rollback("b-1", "v1")
        expect(blob["id"]).to eq("b-1")
        expect(blob["digest"]).to eq("sha512:aa")
      end
    end

    describe ".version_content" do
      it "streams chunks from the version-pinned content URL" do
        conn = stub_connection
        options = Struct.new(:on_data).new
        req = double("req", options: options)
        env = double("env", response_headers: { "content-type" => "application/pdf" })
        expect(conn).to receive(:get).with("/files/b-1/versions/v1/content") do |&blk|
          blk.call(req)
          options.on_data.call("chunk-bytes", 11, env)
        end

        chunks = []
        headers = described_class.version_content("b-1", "v1") { |c| chunks << c }
        expect(chunks).to eq(["chunk-bytes"])
        expect(headers["content-type"]).to eq("application/pdf")
      end
    end
  end
end
