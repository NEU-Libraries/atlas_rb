# frozen_string_literal: true

# Verifies the upload-path extension of RaiseOnResourceError: a verify-on-ingest
# 422 (fixity_mismatch / unsupported_digest_algorithm) on /files or /file_sets
# becomes a typed FixityMismatchError, while other 422s on those paths — and the
# pre-existing reparent/linked/compilation mappings — are unaffected. We drive
# the middleware through Faraday's test adapter (no real HTTP), asserting on the
# raised exception rather than a round-trip.
RSpec.describe AtlasRb::Middleware::RaiseOnResourceError do
  def connection(&stub_block)
    Faraday.new do |f|
      f.use described_class
      f.adapter :test, &stub_block
    end
  end

  describe "fixity (upload paths)" do
    it "raises FixityMismatchError on a 422 fixity_mismatch to POST /files" do
      conn = connection do |s|
        s.post("/files/") { [422, {}, '{"error":"fixity_mismatch","message":"bytes do not match"}'] }
      end
      expect { conn.post("/files/") }.to raise_error(AtlasRb::FixityMismatchError) do |e|
        expect(e.code).to eq("fixity_mismatch")
        expect(e.message).to eq("bytes do not match")
      end
    end

    it "raises FixityMismatchError on a 422 to the FileSet attach (PATCH /file_sets/:id)" do
      conn = connection do |s|
        s.patch("/file_sets/fs-1") do
          [422, {}, '{"error":"unsupported_digest_algorithm","resource_id":"fs-1"}']
        end
      end
      expect { conn.patch("/file_sets/fs-1") }.to raise_error(AtlasRb::FixityMismatchError) do |e|
        expect(e.code).to eq("unsupported_digest_algorithm")
        expect(e.resource_id).to eq("fs-1")
      end
    end

    it "passes a 422 with a non-fixity discriminator on an upload path through untouched" do
      conn = connection do |s|
        s.patch("/file_sets/fs-1") { [422, {}, '{"error":"something_else"}'] }
      end
      expect(conn.patch("/file_sets/fs-1").status).to eq(422)
    end

    it "leaves a 403 on an upload path raw (acting-as/authz isn't translated here)" do
      conn = connection do |s|
        s.post("/files/") { [403, {}, '{"error":"forbidden"}'] }
      end
      expect(conn.post("/files/").status).to eq(403)
    end
  end

  describe "pre-existing mappings (regression)" do
    it "still raises ReparentError on a 422 to .../parent" do
      conn = connection do |s|
        s.patch("/works/w-1/parent") { [422, {}, '{"error":"cycle","resource_id":"w-1"}'] }
      end
      expect { conn.patch("/works/w-1/parent") }.to raise_error(AtlasRb::ReparentError) do |e|
        expect(e.code).to eq("cycle")
      end
    end

    it "still raises ForbiddenError on a 403 to a covered path" do
      conn = connection do |s|
        s.post("/compilations") { [403, {}, '{"error":"forbidden","action":"create"}'] }
      end
      expect { conn.post("/compilations") }.to raise_error(AtlasRb::ForbiddenError)
    end
  end
end
