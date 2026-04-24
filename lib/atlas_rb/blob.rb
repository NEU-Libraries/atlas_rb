# frozen_string_literal: true

module AtlasRb
  class Blob < Resource
    ROUTE = "/files/"

    def self.find(id)
      JSON.parse(connection({}).get(ROUTE + id)&.body)['blob']
    end

    def self.content(id, &chunk_handler)
      headers = {}
      connection({}).get("#{ROUTE}#{id}/content") do |req|
        req.options.on_data = proc do |chunk, _bytes_received, env|
          headers = env.response_headers if headers.empty? && env
          chunk_handler.call(chunk)
        end
      end
      headers
    end

    def self.create(id, blob_path, original_filename)
      payload = { work_id: id,
                  original_filename: original_filename,
                  binary: Faraday::Multipart::FilePart.new(File.open(blob_path),
                                                          "application/octet-stream",
                                                          File.basename(blob_path)) }

      JSON.parse(multipart({}).post(ROUTE, payload)&.body)['blob']
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
