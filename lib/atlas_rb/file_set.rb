# frozen_string_literal: true

module AtlasRb
  class FileSet < Resource
    ROUTE = "/file_sets/"

    def self.find(id)
      connection({}).get(ROUTE + id)&.body
    end

    def self.create(id, classification)
      connection({ work_id: id, classification: classification }).post(ROUTE)&.body
    end

    def self.destroy(id)
      connection({}).delete(ROUTE + id)
    end

    def self.update(id, blob_path)
      # Need to figure out blob vs XML
      payload = { binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                          "application/octet-stream",
                                                          File.basename(blob_path)) }
      multipart({}).patch(ROUTE + id, payload)&.body
    end
  end
end
