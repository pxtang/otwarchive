require "uri"

module Ao3Backup
  class SourceIdentity
    HOST = "archiveofourown.org".freeze
    attr_reader :work_id

    def self.parse(url)
      uri = URI.parse(url.to_s)
      match = uri.path&.match(%r{\A/works/([1-9]\d*)(?:/chapters/[1-9]\d*)?/?\z})
      unless uri.scheme == "https" && uri.host == HOST && uri.port == 443 && uri.userinfo.nil? && match
        raise Error.new(:invalid_source, "Enter an HTTPS archiveofourown.org work or chapter URL.")
      end
      new(match[1])
    rescue URI::InvalidURIError
      raise Error.new(:invalid_source, "The source URL is malformed.")
    end

    def initialize(work_id)
      @work_id = work_id.to_s.freeze
      freeze
    end

    def canonical_url = "https://#{HOST}/works/#{work_id}"
    def fetch_url = "#{canonical_url}?view_full_work=true&view_adult=true"
    def to_h = { "source_host" => HOST, "source_work_id" => work_id, "canonical_url" => canonical_url }
  end
end
