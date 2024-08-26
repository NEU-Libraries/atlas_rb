# frozen_string_literal: true

module AtlasRb
  class Work < Resource
    ROUTE = "/works/"

    def self.find(id)
      JSON.parse(connection({}).get(ROUTE + id)&.body)["work"]
    end

    def self.create(id, xml_path = nil)
      result = JSON.parse(connection({ collection_id: id }).post(ROUTE)&.body)["work"]
      return result unless xml_path.present?

      update(result["id"], xml_path)
      find(result["id"])
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

    def self.metadata(id, values)
      JSON.parse(connection({ metadata: values }).patch(ROUTE + id)&.body)
    end

    def self.mods(id, kind = nil)
      # json default, html, xml
      connection({}).get(
        ROUTE + id + '/mods' + (kind.present? ? ".#{kind}" : '')
        )&.body
    end
  end
end
