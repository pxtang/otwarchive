require "digest"

module Ao3Backup
  CapturedPage = Data.define(:identity, :html, :retrieved_at, :digest) do
    def self.build(identity:, html:, retrieved_at:)
      new(identity: identity, html: html.dup.freeze, retrieved_at: retrieved_at,
          digest: Digest::SHA256.hexdigest(html))
    end
  end
end
