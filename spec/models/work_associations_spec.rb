# frozen_string_literal: true

# The three association bindings, asserted at the binding shape rather than
# over a round-trip: the transport is stubbed so we can capture the params and
# the route each one builds. The route matters here — the DELETE carries the
# predicate as a path segment, not a query parameter, because the type is part
# of the edge's identity.
RSpec.describe AtlasRb::Work do
  let(:body) do
    '{"outbound":{"is_codebook_for":["w-123"]},"inbound":{}}'
  end

  # Records the params handed to `connection` and the route the verb is called
  # with, and answers with a canned associations envelope.
  def stub_transport(verb)
    @params = nil
    @route  = nil
    conn = instance_double(Faraday::Connection)
    allow(conn).to receive(verb) do |route|
      @route = route
      instance_double(Faraday::Response, status: 200, success?: true, body: body)
    end
    allow(described_class).to receive(:connection) do |params, _nuid, **_kwargs|
      @params = params
      conn
    end
  end

  describe ".associations" do
    it "GETs the associations sub-resource and returns both ends" do
      stub_transport(:get)

      result = described_class.associations("w-789")

      expect(@route).to eq("/works/w-789/associations")
      expect(result["outbound"]).to eq("is_codebook_for" => ["w-123"])
      expect(result["inbound"]).to eq({})
    end
  end

  describe ".associate" do
    it "POSTs the target and the type, and returns the updated associations" do
      stub_transport(:post)

      result = described_class.associate("w-789", "w-123", type: "is_codebook_for")

      expect(@route).to eq("/works/w-789/associations")
      expect(@params).to eq(work_id: "w-123", type: "is_codebook_for")
      expect(result["outbound"]).to eq("is_codebook_for" => ["w-123"])
    end
  end

  describe ".disassociate" do
    # Two Works can hold two different edges at once, so the predicate has to
    # travel in the path or the wrong edge could be retracted.
    it "puts the type and the target in the path, not the query" do
      stub_transport(:delete)

      described_class.disassociate("w-789", "w-123", type: "is_codebook_for")

      expect(@route).to eq("/works/w-789/associations/is_codebook_for/w-123")
      expect(@params).to eq({})
    end

    it "accepts a symbol type" do
      stub_transport(:delete)

      described_class.disassociate("w-789", "w-123", type: :is_figure_for)

      expect(@route).to eq("/works/w-789/associations/is_figure_for/w-123")
    end
  end

  describe "ASSOCIATION_TYPES" do
    it "carries the five predicates Atlas accepts" do
      expect(described_class::ASSOCIATION_TYPES).to eq(
        %w[is_codebook_for is_figure_for is_instructional_material_for
           is_supplemental_material_for is_transcription_of]
      )
    end
  end
end
