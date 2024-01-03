# frozen_string_literal: true

module AtlasRb
  class Collection < Resource
    ROUTE = "/collections/"

    def self.find(id)
      JSON.parse(connection({}).get(ROUTE + id)&.body)["collection"]
    end

    def self.create(id)
      # params[:parent_id]
      JSON.parse(connection({ parent_id: id }).post(ROUTE)&.body)["collection"]
    end

    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    def self.children(id)
      JSON.parse(connection({}).get(ROUTE + id + '/children')&.body)
    end

    def self.update(id, xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      JSON.parse(multipart({}).patch(ROUTE + id, payload)&.body)
    end
  end
end
