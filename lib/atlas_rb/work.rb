# frozen_string_literal: true

module AtlasRb
  class Work < Resource
    ROUTE = "/works/"

    def self.find(id)
      connection({}).get(ROUTE + id)&.body
    end

    def self.create(id)
      # params[:collection_id]
      connection({ collection_id: id }).post(ROUTE)&.body
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
