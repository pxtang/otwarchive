require "net/http"
require "json"

module Ao3Backup
  class HttpClient
    MAX_RESPONSE_BYTES = 8 * 1024 * 1024

    def call(endpoint, payload)
      uri = URI(endpoint)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
        raise Error.new(:solver_configuration, "Configure a valid solver endpoint on the server.")
      end
      uri.path = "#{uri.path.sub(%r{/+\z}, '')}/v1"
      uri.query = uri.fragment = nil
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 75
      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      request.body = JSON.generate(payload)
      body = +""
      status = headers = nil
      http.request(request) do |response|
        status, headers = response.code.to_i, response.to_hash
        response.read_body do |chunk|
          body << chunk
          raise Error.new(:response_too_large, "Solver response exceeds the 8 MiB limit.") if body.bytesize > MAX_RESPONSE_BYTES
        end
      end
      { status: status, body: body, headers: headers }
    rescue URI::InvalidURIError
      raise Error.new(:solver_configuration, "Configure a valid solver endpoint on the server.")
    end
  end
end
