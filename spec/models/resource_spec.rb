# frozen_string_literal: true

RSpec.describe AtlasRb::Resource do
  # The seven Valkyrie-backed types Atlas's resolver answers with. Stated here
  # so a new subclass that should have called `unresolvable!` fails this spec
  # rather than registering silently.
  let(:resolvable) do
    [AtlasRb::Work, AtlasRb::Collection, AtlasRb::Community, AtlasRb::FileSet,
     AtlasRb::Blob, AtlasRb::Delegate, AtlasRb::Person]
  end

  describe "TYPES" do
    it "registers exactly the types the Atlas resolver returns" do
      expect(described_class::TYPES.values.uniq).to match_array(resolvable)
    end

    it "is frozen once the subclasses have loaded" do
      expect(described_class::TYPES).to be_frozen
    end

    it "derives each wire key from the class name" do
      expect(described_class::TYPES.keys).to include(
        "work", "collection", "community", "file_set", "blob", "delegate", "person"
      )
    end

    it "leaves out a subclass defined after the gem has loaded" do
      Class.new(described_class)
      stub_const("AtlasRb::LateType", Class.new(described_class))

      expect(described_class::TYPES.values).not_to include(AtlasRb::LateType)
    end
  end

  describe ".resolve_type" do
    it "accepts the wire key and the class name" do
      expect(described_class.resolve_type("file_set")).to eq(AtlasRb::FileSet)
      expect(described_class.resolve_type("FileSet")).to eq(AtlasRb::FileSet)
    end

    it "accepts a symbol" do
      expect(described_class.resolve_type(:work)).to eq(AtlasRb::Work)
    end

    it "raises on a Compilation, which the resolver never returns" do
      expect { described_class.resolve_type("Compilation") }
        .to raise_error(ArgumentError, /unknown Atlas resource type/)
    end

    it "raises on the pre-1.17.0 spelling" do
      expect { described_class.resolve_type("File_set") }.to raise_error(ArgumentError)
    end
  end

  describe ".mods_editable?" do
    it "is true for exactly the types Atlas takes a MODS write for" do
      editable = (resolvable + [AtlasRb::Compilation]).select(&:mods_editable?)

      expect(editable).to match_array([AtlasRb::Work, AtlasRb::Collection, AtlasRb::Community])
    end
  end
end
