# frozen_string_literal: true

RSpec.describe AtlasRb::Mash do
  describe "#resource_class" do
    it "resolves the row's klass" do
      expect(described_class.new("klass" => "FileSet").resource_class).to eq(AtlasRb::FileSet)
    end

    it "resolves a nested row, as an ancestors node arrives" do
      row = described_class.new("resource" => { "ancestors" => [{ "klass" => "Collection" }] })

      expect(row.resource.ancestors.first.resource_class).to eq(AtlasRb::Collection)
    end

    it "raises on a Compilation, which no Atlas payload reports" do
      expect { described_class.new("klass" => "Compilation").resource_class }
        .to raise_error(ArgumentError)
    end

    it "raises on a row with no klass" do
      expect { described_class.new("noid" => "abc123").resource_class }
        .to raise_error(ArgumentError, /nil/)
    end

    it "leaves the row plain data" do
      row = described_class.new("klass" => "Work")
      row.resource_class

      expect(row.to_h).to eq("klass" => "Work")
    end
  end
end
