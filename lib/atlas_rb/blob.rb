# frozen_string_literal: true

module AtlasRb
  class Blob < Resource
    ROUTE = "/files/"
  end

  def self.find(id)
    connection({}).get(ROUTE + id)&.body
  end

  def self.create(id, blob_path)
    payload = { binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                         "application/octet-stream",
                                                         File.basename(blob_path)) }

    multipart({ work_id: id }).post(ROUTE, payload)&.body
  end

  def self.destroy(id)
    connection({}).delete(ROUTE + id)
  end

  def self.update(id, blob_path)
    payload = { binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                         "application/octet-stream",
                                                         File.basename(blob_path)) }
    multipart({}).patch(ROUTE + id, payload)&.body
  end
end
