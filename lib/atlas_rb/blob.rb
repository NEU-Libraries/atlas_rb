# frozen_string_literal: true

module AtlasRb
  class Blob < Resource
    ROUTE = "/files/"

    def self.find(id)
      JSON.parse(connection({}).get(ROUTE + id)&.body)['blob']
    end

    def self.create(id, blob_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                          "application/octet-stream",
                                                          File.basename(blob_path)) }

      JSON.parse(multipart({ work_id: id }).post(ROUTE, payload)&.body)['blob']
    end

    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    def self.update(id, blob_path)
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                          "application/octet-stream",
                                                          File.basename(blob_path)) }
      JSON.parse(multipart({}).patch(ROUTE + id, payload)&.body)
    end
  end
end
