# Run with bundle exec rails runner script/docker/check_flaresolverr.rb SOURCE_URL.
# Read-only: this diagnostic never creates archive records or stores source HTML.
begin
  identity = Ao3Backup::SourceIdentity.parse(ARGV.fetch(0))
  page = Ao3Backup::Provider.new.call(identity)
  manifest = Ao3Backup::Parser.new.call(page)
  puts JSON.pretty_generate(status: "ok", source_url: identity.canonical_url,
                            title: manifest.dig("scalars", "title"),
                            chapters: "#{manifest['published_chapters']}/#{manifest.dig('scalars', 'expected_chapters') || '?'}",
                            chapter_ids: manifest["chapters"].map { |chapter| chapter["source_chapter_id"] },
                            tag_counts: manifest["tags"].group_by { |tag| tag["type"] }.transform_values(&:length))
rescue Ao3Backup::Error, IndexError => error
  abort "#{error.respond_to?(:code) ? error.code : 'usage'}: #{error.message}"
end
