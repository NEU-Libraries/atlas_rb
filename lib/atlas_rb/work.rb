# frozen_string_literal: true

module AtlasRb
  class Work < Resource
    ROUTE = "/works/"

    def self.find(id)
      JSON.parse(connection({}).get(ROUTE + id)&.body)["work"]
    end

    def self.create(id)
      # params[:collection_id]
      JSON.parse(connection({ collection_id: id }).post(ROUTE)&.body)["work"]
    end

    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    def self.update(id, xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      JSON.parse(multipart({}).patch(ROUTE + id, payload)&.body)
    end

    def self.mods(id)
      connection({}).get(ROUTE + id + '/mods.html')&.body
    end

    def self.xml(id)
      connection({}).get(ROUTE + id + '/mods')&.body
    end
  end
end
