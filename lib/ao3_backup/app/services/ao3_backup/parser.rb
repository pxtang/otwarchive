require "nokogiri"
require "date"

module Ao3Backup
  class Parser
    include ::HtmlCleaner
    TAG_TYPES = { "rating" => "Rating", "warning" => "ArchiveWarning", "category" => "Category",
                  "fandom" => "Fandom", "relationship" => "Relationship", "character" => "Character",
                  "freeform" => "Freeform" }.freeze

    def call(page)
      @page = page
      @remote_dependencies = []
      document = Nokogiri::HTML5.parse(page.html)
      if !document.at_css("#workskin") && document.at_css('a[href*="view_adult"]')
        fail_with(:adult_warning, "Source requires adult-content acknowledgement.")
      end
      if !document.at_css("#workskin") &&
         (document.at_css("#challenge-running, #challenge-form, .cf-turnstile") ||
          document.at_css("head > title")&.text.to_s.match?(/Checking your browser|Just a moment|Verify you are human/i))
        fail_with(:verification_required, "Source verification is still present. Retry later.")
      end
      title = document.at_css("#workskin > .preface h2.title")&.text&.strip
      fail_with(:malformed_work, "Missing source work title or metadata.") if title.to_s.empty? || !document.at_css("dl.work.meta")
      fraction = document.at_css("dl.work.meta dd.stats dd.chapters")&.text&.strip
      match = fraction.to_s.match(/\A([1-9]\d*)\/(\?|[1-9]\d*)\z/)
      fail_with(:incomplete_work, "Invalid published/expected chapter counts.") unless match
      published = match[1].to_i
      expected = match[2] == "?" ? nil : match[2].to_i
      fail_with(:incomplete_work, "Expected total is smaller than published chapters.") if expected && expected < published
      wrappers = document.css("#chapters > .chapter")
      direct_bodies = document.css("#chapters > .userstuff")
      if wrappers.empty?
        fail_with(:incomplete_work, "Single work requires exactly one body and published count 1.") unless published == 1 && direct_bodies.length == 1
        chapters = [chapter_data(document.at_css("#chapters"), direct_bodies.first, 1, nil)]
      else
        fail_with(:incomplete_work, "Published chapter bodies are missing or ambiguous.") unless wrappers.length == published && direct_bodies.empty?
        chapters = wrappers.each_with_index.map do |node, index|
          fail_with(:incomplete_work, "Chapter positions are missing, duplicated, or out of order.") unless node["id"] == "chapter-#{index + 1}"
          bodies = node.css('> .userstuff[role="article"]')
          fail_with(:incomplete_work, "Each chapter needs exactly one body.") unless bodies.length == 1
          link = (node.at_css("> .preface > h3.title a[href]") || node.at_css("> h3.title a[href]"))&.[]("href")
          uri = safe_url(link)
          chapter_match = URI(uri.to_s).path.match(%r{\A/works/#{page.identity.work_id}/chapters/([1-9]\d*)\z})
          fail_with(:incomplete_work, "Missing or incorrect source chapter identity.") unless uri&.start_with?("https://archiveofourown.org/") && chapter_match
          chapter_data(node, bodies.first, index + 1, chapter_match[1])
        end
        ids = chapters.map { |chapter| chapter["source_chapter_id"] }
        fail_with(:incomplete_work, "Duplicate source chapter identities.") unless ids.uniq.length == ids.length
      end
      authors = document.css("#workskin > .preface .byline a[rel='author']").map { |node| node.text.strip }
      authors = document.css("#workskin > .preface .byline a").map { |node| node.text.strip } if authors.empty?
      authors = [document.at_css("#workskin > .preface .byline")&.text.to_s.strip] if authors.empty?
      authors.reject!(&:empty?)
      fail_with(:malformed_work, "Source author attribution is missing.") if authors.empty?
      tags = TAG_TYPES.flat_map do |css_type, local_type|
        document.css("dl.work.meta dd.#{css_type} a.tag").map { |node| { "type" => local_type, "name" => node.text.strip } }
      end
      tags.each { |tag| limit!(tag["name"], ArchiveConfig.TAG_MAX, "tag") }
      authors.each { |author| limit!(author, ArchiveConfig.TAG_MAX, "author tag") }
      scalars = { "title" => title, "language" => document.at_css("dl.work.meta dd.language")&.text.to_s.strip,
                  "summary" => html(document.at_css("#workskin > .preface .summary blockquote.userstuff"), "summary"),
                  "notes" => html(document.at_css("#workskin > .preface .notes blockquote.userstuff"), "notes"),
                  "endnotes" => html(document.at_css("#work_endnotes blockquote.userstuff, #workskin > .afterword .notes blockquote.userstuff"), "endnotes"),
                  "published_at" => date(document.at_css("dl.work.meta dd.stats dd.published")),
                  "status_date" => date(document.at_css("dl.work.meta dd.stats dd.status")),
                  "status_label" => document.at_css("dl.work.meta dd.stats dt.status")&.text&.strip,
                  "expected_chapters" => expected,
                  "series" => document.css("dl.work.meta dd.series .position").map { |node| node.text.strip }.join("; "),
                  "source_attribution" => page.identity.canonical_url }
      limit!(title, ArchiveConfig.TITLE_MAX, "title")
      { "schema_version" => 1, "identity" => page.identity.to_h, "retrieved_at" => page.retrieved_at.iso8601,
        "digest" => page.digest, "scalars" => scalars, "authors" => authors, "tags" => tags,
        "published_chapters" => published, "complete" => !expected.nil? && expected == published,
        "source_word_count" => document.at_css("dl.work.meta dd.stats dd.words")&.text&.strip,
        "chapters" => chapters, "remote_dependencies" => @remote_dependencies.to_a.uniq }
    end

    private

    def chapter_data(node, body, position, source_id)
      copy = body.dup
      copy.css("> h3.landmark.heading").remove
      content = html(copy, "content")
      retained = Nokogiri::HTML5.fragment(content)
      media = retained.css("img[src], audio[src], audio source[src], video[src], video source[src], iframe[src], object[data]")
      fail_with(:incomplete_work, "Chapter body is empty after removing page landmarks and unsafe markup.") if retained.text.strip.empty? && media.empty?
      heading = source_id ? (node.at_css("> .preface > h3.title") || node.at_css("> h3.title"))&.dup : nil
      # AO3's chapter number is a navigation link, not part of the user's title.
      heading&.css("a[href]")&.remove
      chapter_title = heading&.text&.sub(/\A\s*:\s*/, "")&.strip
      chapter_title = nil if chapter_title.to_s.empty?
      limit!(chapter_title, ArchiveConfig.TITLE_MAX, "chapter title")
      { "position" => position, "source_chapter_id" => source_id,
        "title" => chapter_title,
        "content" => content,
        "summary" => html(node.at_css(".preface .summary blockquote.userstuff"), "summary"),
        "notes" => html(node.at_css(".preface .notes blockquote.userstuff"), "notes"),
        "endnotes" => html(node.at_css('[id$="_endnotes"] blockquote.userstuff, .end .notes blockquote.userstuff'), "endnotes") }
    end

    def html(node, field)
      return "" unless node
      copy = node.dup
      copy.css("a[href], img[src], audio[src], video[src], source[src]").each do |element|
        attribute = element.name == "a" ? "href" : "src"
        url = safe_url(element[attribute])
        if url
          element[attribute] = url
          (@remote_dependencies ||= []) << url if element.name != "a" && URI(url).host != SourceIdentity::HOST
        else
          element.remove_attribute(attribute)
        end
      end
      value = sanitize_value(field, copy.inner_html)
      max = field == "content" ? ArchiveConfig.CONTENT_MAX : field == "summary" ? ArchiveConfig.SUMMARY_MAX : ArchiveConfig.NOTES_MAX
      limit!(value, max, field)
      value
    end

    def safe_url(value)
      return nil if value.to_s.empty?
      uri = URI.join(@page.identity.canonical_url, value)
      uri.to_s if %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
    rescue URI::InvalidURIError
      nil
    end

    def date(node)
      return nil if node.nil? || node.text.strip.empty?
      Date.iso8601(node.text.strip).iso8601
    rescue Date::Error
      fail_with(:malformed_work, "Source has an invalid date.")
    end

    def limit!(value, maximum, field)
      fail_with(:field_too_long, "Source #{field} exceeds the local #{maximum}-character limit; content was not truncated.") if value.to_s.length > maximum
    end

    def fail_with(code, message)
      raise Error.new(code, message)
    end
  end
end
