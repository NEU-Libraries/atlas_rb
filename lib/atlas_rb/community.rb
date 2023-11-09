# frozen_string_literal: true

module AtlasRb
  class Community < Resource
    ROUTE = "/communities/"

    def self.find(id)
      JSON.parse(connection({}).get(ROUTE + id)&.body)
    end

    def self.create(id = nil)
      JSON.parse(connection({ parent_id: id }).post(ROUTE)&.body)
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
