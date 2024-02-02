# frozen_string_literal: true

module AtlasRb
  class Resource
    extend AtlasRb::FaradayHelper

    def self.find(id)
      result = JSON.parse(connection({}).get('/resources/' + id)&.body)
      { "klass" => result.first[0].capitalize,
        "resource" => result.first[1] }
    end

    def self.preview(xml_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(xml_path),
                                                           "application/xml",
                                                           File.basename(xml_path)) }
      multipart({ work_id: id }).post('/resources/preview', payload)&.body
    end
  end
end
