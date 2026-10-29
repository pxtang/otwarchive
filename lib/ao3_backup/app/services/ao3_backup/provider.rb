require "json"

module Ao3Backup
  class Provider
    MAX_HTML_BYTES = 5 * 1024 * 1024

    def initialize(endpoint: ENV["AO3_FLARESOLVERR_URL"], client: HttpClient.new, clock: -> { Time.current })
      @endpoint, @client, @clock = endpoint, client, clock
    end

    def call(identity)
      raise Error.new(:solver_configuration, "AO3_FLARESOLVERR_URL is not configured on the server.") if @endpoint.to_s.empty?
      response = @client.call(@endpoint, { cmd: "request.get", url: identity.fetch_url, maxTimeout: 60_000 })
      unless response[:status] == 200
        retry_after = Array(response.fetch(:headers, {})["retry-after"]).first
        raise Error.new(:solver_http_error, "Solver API returned HTTP #{response[:status]}.", retry_after: retry_after)
      end
      raise Error.new(:response_too_large, "Solver response exceeds the 8 MiB limit.") if response[:body].to_s.bytesize > HttpClient::MAX_RESPONSE_BYTES
      envelope = JSON.parse(response[:body])
      raise Error.new(:malformed_response, "Solver returned a malformed JSON envelope.") unless envelope.is_a?(Hash)
      raise Error.new(:solver_error, "Solver could not complete verification. Retry later.") unless envelope["status"] == "ok"
      solution = envelope["solution"]
      unless solution.is_a?(Hash) && solution["status"].is_a?(Integer) && solution["url"].is_a?(String) && solution["response"].is_a?(String)
        raise Error.new(:malformed_response, "Solver response is missing the target status, URL, or HTML.")
      end
      status = solution["status"]
      raise Error.new(:missing_work, "The source work was not found.") if status == 404
      unless status == 200
        code = { 403 => :target_forbidden, 429 => :target_rate_limited, 525 => :target_tls_error }.fetch(status, :target_error)
        headers = solution["headers"].is_a?(Hash) ? solution["headers"] : {}
        retry_after = headers.find { |key, _| key.to_s.downcase == "retry-after" }&.last
        raise Error.new(code, "Source returned HTTP #{status}. Retry later.", retry_after: retry_after)
      end
      begin
        final = SourceIdentity.parse(solution["url"])
      rescue Error
        raise Error.new(:unexpected_redirect, "Solver ended outside the supported source work page.")
      end
      final_uri = URI(solution["url"])
      unless final.work_id == identity.work_id && final_uri.path.sub(%r{/\z}, "") == "/works/#{identity.work_id}"
        raise Error.new(:unexpected_redirect, "Solver did not return the requested full work page.")
      end
      html = solution["response"]
      raise Error.new(:response_too_large, "Work HTML exceeds the 5 MiB limit.") if html.bytesize > MAX_HTML_BYTES
      CapturedPage.build(identity: identity, html: html, retrieved_at: @clock.call)
    rescue JSON::ParserError, TypeError
      raise Error.new(:malformed_response, "Solver returned invalid JSON.")
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error.new(:solver_timeout, "Solver timed out. Retry later.")
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError
      raise Error.new(:solver_unreachable, "Cannot reach the configured solver. Check the service and retry.")
    end
  end
end
