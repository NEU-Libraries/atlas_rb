# frozen_string_literal: true

module AtlasRb
  class Collection < Resource
    ROUTE = "/collections/"

    def self.find(id)
      connection({}).get(ROUTE + id)&.body
    end

    def self.create
      connection({}).post(ROUTE)&.body
    end

    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    def self.update(id, xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      multipart({}).patch(ROUTE + id, payload)&.body
    end
  end
end
