require "spec_helper"

module MagicImportFixtures
  def captured(name = "2_unknown", html: nil)
    Ao3Backup::CapturedPage.build(identity: Ao3Backup::SourceIdentity.parse("https://archiveofourown.org/works/12345"),
                                  html: html || File.read(Rails.root.join("spec/fixtures/ao3_backup/#{name}.html")),
                                  retrieved_at: Time.utc(2026, 10, 28))
  end
end

RSpec.describe Ao3Backup::SourceIdentity do
  it "normalizes work and chapter URLs to a single full-work request" do
    identity = described_class.parse("https://archiveofourown.org/works/12345/chapters/501?view_adult=true#main")
    expect(identity.canonical_url).to eq("https://archiveofourown.org/works/12345")
    expect(identity.fetch_url).to eq("https://archiveofourown.org/works/12345?view_full_work=true&view_adult=true")
  end

  ["http://archiveofourown.org/works/12345", "https://example.org/works/12345",
   "https://user@archiveofourown.org/works/12345", "https://archiveofourown.org:444/works/12345",
   "https://archiveofourown.org/works/0", "https://archiveofourown.org/users/12345",
   "chrome://new-tab-page/", "%%%"].each do |url|
    it("rejects unsupported source #{url}") { expect { described_class.parse(url) }.to raise_error(Ao3Backup::Error) }
  end
end

RSpec.describe Ao3Backup::Parser do
  include MagicImportFixtures

  [["1_1", 1, 1], ["7_7", 7, 7], ["2_unknown", 2, nil], ["10_12", 10, 12]].each do |fixture, published, expected|
    it "parses every published body and separate metadata for #{fixture}" do
      manifest = described_class.new.call(captured(fixture))
      expect(manifest["schema_version"]).to eq(1)
      expect(manifest["published_chapters"]).to eq(published)
      expect(manifest.dig("scalars", "expected_chapters")).to eq(expected)
      expect(manifest["complete"]).to eq(expected == published)
      expect(manifest["chapters"].length).to eq(published)
      expect(manifest["chapters"].count { |chapter| chapter["summary"].present? }).to eq(published > 2 ? published - 1 : published == 2 ? 1 : 0)
      expect(manifest["authors"]).to eq(["Invented_Author"])
      expect(manifest.dig("scalars", "published_at")).to eq("2026-10-26")
      expect(manifest.dig("scalars", "series")).to eq("Part 1 of Invented Cycle")
      expect(manifest.dig("scalars", "notes")).to include("Work beginning")
      expect(manifest.dig("scalars", "endnotes")).to include("Work ending")
      expect(manifest["tags"].select { |tag| tag["type"] == "Fandom" }.map { |tag| tag["name"] }).to eq(["呪術廻戦 | Jujutsu Kaisen (Anime)", "呪術廻戦 | Jujutsu Kaisen (Manga)"])
      expect(manifest.dig("chapters", 0, "content")).to include("A user heading", "https://archiveofourown.org/works/12345")
      expect(manifest.dig("chapters", 0, "content")).not_to include("script", "Chapter Text")
      expect(manifest["remote_dependencies"]).to eq(["https://media.example/scene.png"])
      if published == 1
        expect(manifest.dig("chapters", 0, "source_chapter_id")).to be_nil
        expect(manifest.dig("scalars", "status_date")).to be_nil
      else
        expect(manifest.dig("chapters", -1, "source_chapter_id")).to eq((500 + published).to_s)
        expect(manifest.dig("chapters", -1, "endnotes")).to include("Ending chapter note")
      end
    end
  end

  it "does not mistake challenge phrases inside valid prose for an interstitial" do
    html = captured.html.sub("Invented prose chapter 1.", "Just a moment. Checking your browser. Verify you are human, said the invented character.")
    expect(described_class.new.call(captured(html: html)).dig("chapters", 0, "content")).to include("Just a moment")
  end

  it "rejects landmark-only and sanitizer-empty bodies but allows retained media" do
    ["<h3 class='landmark heading'>Chapter Text</h3>",
     "<h3 class='landmark heading'>Chapter Text</h3><script>alert(1)</script>",
     "<h3 class='landmark heading'>Chapter Text</h3><img src='javascript:alert(1)'>"].each do |empty|
      doc = Nokogiri::HTML5.parse(captured.html)
      doc.at_css('#chapter-1 > .userstuff[role="article"]').inner_html = empty
      expect { described_class.new.call(captured(html: doc.to_html)) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("incomplete_work") }
    end
    doc = Nokogiri::HTML5.parse(captured.html)
    doc.at_css('#chapter-1 > .userstuff[role="article"]').inner_html = '<img src="https://media.example/scene.png">'
    expect(described_class.new.call(captured(html: doc.to_html)).dig("chapters", 0, "content")).to include("scene.png")
  end

  it "extracts only the author's chapter title and leaves untitled chapters absent" do
    manifest = described_class.new.call(captured)
    expect(manifest.dig("chapters", 0, "title")).to eq("Invented chapter 1")
    html = captured.html.sub(": Invented chapter 1", "")
    expect(described_class.new.call(captured(html: html)).dig("chapters", 0, "title")).to be_nil
  end

  it "keeps a title-styled user heading inside a single body without inventing a chapter title" do
    html = captured("1_1").html.sub("<h3>A user heading</h3>", '<h3 class="title">Authored prose heading</h3>')
    chapter = described_class.new.call(captured(html: html)).fetch("chapters").first
    expect(chapter["title"]).to be_nil
    expect(chapter["content"]).to include("Authored prose heading")
  end

  it "resets dependency state when a parser instance is reused" do
    parser = described_class.new
    parser.call(captured)
    second = captured(html: captured.html.gsub('<img src="https://media.example/scene.png">', ""))
    expect(parser.call(second)["remote_dependencies"]).to eq([])
  end

  ["7_7", "10_12", "2_unknown"].each do |name|
    it "rejects missing, duplicate and invalid bodies or identities for #{name}" do
      source = captured(name).html
      [source.sub('id="chapter-2"', 'id="chapter-1"'),
       source.sub('/chapters/502', '/chapters/501'),
       source.sub('/works/12345/chapters/502', '/works/99999/chapters/502'),
       source.sub('role="article"', 'role="missing"'),
       source.sub('id="chapter-2"', 'id="unexpected"')].each do |bad|
        expect { described_class.new.call(captured(html: bad)) }.to raise_error(Ao3Backup::Error)
      end
      doc = Nokogiri::HTML5.parse(source)
      doc.at_css("#chapter-2").remove
      expect { described_class.new.call(captured(html: doc.to_html)) }.to raise_error(Ao3Backup::Error)
      doc = Nokogiri::HTML5.parse(source)
      doc.at_css("#chapter-1") << doc.at_css('#chapter-1 > .userstuff[role="article"]').dup
      expect { described_class.new.call(captured(html: doc.to_html)) }.to raise_error(Ao3Backup::Error)
    end
  end

  it "rejects inconsistent chapter fractions and duplicate unwrapped bodies" do
    source = captured("1_1").html
    [source.sub("1/1", "2/1"), source.sub("1/1", "1/0"), source.sub("1/1", "unknown")].each do |bad|
      expect { described_class.new.call(captured(html: bad)) }.to raise_error(Ao3Backup::Error)
    end
    doc = Nokogiri::HTML5.parse(source)
    doc.at_css("#chapters") << doc.at_css("#chapters > .userstuff").dup
    expect { described_class.new.call(captured(html: doc.to_html)) }.to raise_error(Ao3Backup::Error)
  end

  it "reports adult warning and challenge pages distinctly" do
    expect { described_class.new.call(captured(html: '<a href="?view_adult=true">Yes, Continue</a>')) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("adult_warning") }
    expect { described_class.new.call(captured(html: '<title>Just a moment</title><div id="challenge-running"></div>')) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("verification_required") }
  end

  it "rejects oversized source fields rather than truncating" do
    source = captured.html.sub("Invented summary.", "x" * (ArchiveConfig.SUMMARY_MAX + 1))
    expect { described_class.new.call(captured(html: source)) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("field_too_long") }
  end
end

RSpec.describe Ao3Backup::Provider do
  include MagicImportFixtures
  let(:identity) { captured.identity }
  let(:endpoint) { "http://solver.internal:8191" }
  let(:envelope) { { status: "ok", solution: { status: 200, url: identity.fetch_url, response: captured.html } } }
  let(:provider) { described_class.new(endpoint: endpoint, clock: -> { Time.utc(2026, 10, 28) }) }

  def solver_response(body: JSON.generate(envelope), status: 200, headers: {})
    stub_request(:post, "#{endpoint}/v1").to_return(status: status, body: body, headers: headers)
  end

  it "requests the full adult-acknowledged work and captures retrieval time/digest" do
    solver_response
    page = provider.call(identity)
    expect(a_request(:post, "#{endpoint}/v1").with(body: JSON.generate(cmd: "request.get", url: identity.fetch_url, maxTimeout: 60_000))).to have_been_made.once
    expect(page.html).to eq(captured.html)
    expect(page.retrieved_at).to eq(Time.utc(2026, 10, 28))
    expect(page.digest).to eq(Digest::SHA256.hexdigest(page.html))
    expect(page.html).to be_frozen
  end

  [["malformed_response", "not json"], ["malformed_response", "[]"],
   ["solver_error", '{"status":"error","message":"secret cookie should never be logged"}'],
   ["malformed_response", '{"status":"ok","solution":{}}']].each do |code, body|
    it "returns typed #{code} for invalid envelope" do
      solver_response(body: body)
      expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq(code); expect(error.message).not_to include("secret") }
    end
  end

  [403, 429, 525, 404].each do |status|
    it "distinguishes target HTTP #{status}" do
      envelope[:solution][:status] = status
      solver_response
      expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq({ 403 => "target_forbidden", 429 => "target_rate_limited", 525 => "target_tls_error", 404 => "missing_work" }.fetch(status)) }
    end
  end

  ["chrome://new-tab-page/", "https://example.org/works/12345", "https://archiveofourown.org/works/99999"].each do |url|
    it "rejects unexpected final URL #{url}" do
      envelope[:solution][:url] = url
      solver_response
      expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("unexpected_redirect") }
    end
  end

  it "reports solver HTTP failures with Retry-After" do
    solver_response(status: 429, headers: { "Retry-After" => "60" })
    expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("solver_http_error"); expect(error.retry_after).to eq("60") }
  end

  it "bounds HTML responses" do
    envelope[:solution][:response] = "x" * (described_class::MAX_HTML_BYTES + 1)
    solver_response
    expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("response_too_large") }
  end

  it "bounds API response bytes before JSON parsing" do
    solver_response(body: "x" * (Ao3Backup::HttpClient::MAX_RESPONSE_BYTES + 1))
    expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("response_too_large") }
  end

  it "distinguishes unavailable and timed out solver transport" do
    stub_request(:post, "#{endpoint}/v1").to_timeout
    expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("solver_timeout") }
    stub_request(:post, "#{endpoint}/v1").to_raise(SocketError)
    expect { provider.call(identity) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("solver_unreachable") }
  end
end

RSpec.describe Ao3Backup::SelectionPolicy do
  include MagicImportFixtures
  let(:manifest) { Ao3Backup::Parser.new.call(captured("10_12")) }
  let(:policy) { described_class.new }

  it "selects author first, existing typed tags next, and new tags last with ratings/warnings unchecked" do
    fandom = Fandom.create!(name: manifest["tags"].find { |tag| tag["type"] == "Fandom" }["name"])
    Rating.create!(name: "Mature", canonical: true)
    ArchiveWarning.create!(name: "Invented Warning", canonical: true)
    count = Tag.count
    selection = policy.initial(manifest)
    expect(Tag.count).to eq(count)
    expect(selection["tags"].first).to include("name" => "Invented_Author", "keep" => true, "author" => true)
    expect(selection["tags"].find { |tag| tag["local_id"] == fandom.id }["keep"]).to eq(true)
    expect(selection["tags"].select { |tag| %w[Rating ArchiveWarning].include?(tag["type"]) }.map { |tag| tag["keep"] }).to eq([false, false])
    expect(selection["tags"].select { |tag| tag["type"] == "Fandom" }.map { |tag| tag["keep"] }).to eq([true, false])
  end

  it "keeps both absent Unicode fandoms distinct and initially unchecked" do
    selection = policy.initial(manifest)
    fandoms = selection["tags"].select { |tag| tag["type"] == "Fandom" }
    expect(fandoms.map { |tag| tag["keep"] }).to eq([false, false])
    edits = selection["tags"].map { |tag| tag.slice("id", "name").merge("keep" => tag["type"] == "Fandom") }
    proposed = policy.proposed(policy.update(selection, "tags" => edits))
    expect(proposed["tags"].map { |tag| tag["name"] }).to eq(fandoms.map { |tag| tag["name"] })
  end

  it "shows cross-type collisions without reclassifying or creating tags" do
    tag = UnsortedTag.create!(name: "Invented Character")
    selection = policy.initial(manifest)
    expect(selection["tags"].find { |candidate| candidate["name"] == tag.name }).to include("status" => "collision", "local_type" => "UnsortedTag", "keep" => false)
    expect(tag.reload.type).to eq("UnsortedTag")
  end

  it "preserves explicit none, edits, and stable ordering across repeated revisions" do
    Freeform.create!(name: "Invented Theme")
    selection = policy.initial(manifest)
    ids = selection["tags"].map { |tag| tag["id"] }
    edits = selection["tags"].reverse.map { |tag| tag.slice("id").merge("name" => tag["name"] == "Invented_Author" ? "Local attribution" : tag["name"], "keep" => false) }
    revised = policy.update(selection, "tags" => edits)
    expect(revised["tags"].map { |tag| tag["id"] }).to eq(ids)
    expect(policy.proposed(policy.update(revised, "scalars" => { "summary" => { "keep" => false } }))["tags"]).to eq([])
    expect(policy.proposed(revised)["tags"]).to eq([])
    expect(selection["tags"].first["name"]).to eq("Invented_Author")
  end

  it "treats explicit empty tag choices as keep none, distinct from omitted choices" do
    selection = policy.initial(manifest)
    expect(policy.proposed(policy.update(selection, "tags" => []))["tags"]).to eq([])
    expect(policy.proposed(policy.update(selection, {}))["tags"].first["name"]).to eq("Invented_Author")
  end

  it "requires local replacements for removed title/language without reinstating the source" do
    selection = policy.initial(manifest)
    expect { policy.update(selection, "scalars" => { "title" => { "keep" => false } }) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("replacement_required") }
    create(:language)
    revised = policy.update(selection, "scalars" => { "title" => { "keep" => false, "replacement" => "A local title" }, "language" => { "keep" => false, "replacement" => "Dutch" }, "summary" => { "keep" => false } })
    expect(policy.proposed(revised)["scalars"]).to include("title" => "A local title", "language" => "Dutch", "summary" => nil)
  end

  it "rejects unavailable languages and completion totals below the published count" do
    selection = policy.initial(manifest)
    [{ "language" => { "keep" => false, "replacement" => "Unavailable language" } },
     { "expected_chapters" => { "value" => 2 } }].each do |fields|
      expect { policy.update(selection, "scalars" => fields) }.to raise_error(Ao3Backup::Error)
    end
  end

  it "deduplicates selected author/freeform identity while preserving the author position" do
    Freeform.create!(name: "Invented_Author")
    manifest["tags"] << { "type" => "Freeform", "name" => "Invented_Author" }
    expect(policy.proposed(policy.initial(manifest))["tags"].count { |tag| tag["name"] == "Invented_Author" }).to eq(1)
  end

  it "rejects unknown edits, missing choices, invalid booleans and chapter body edits" do
    selection = policy.initial(manifest)
    [{ "unknown" => true }, { "tags" => [{ "id" => "0", "keep" => true }] },
     { "scalars" => { "title" => { "keep" => "false" } } },
     { "chapters" => { "1" => { "content" => { "keep" => false } } } },
     { "scalars" => { "summary" => { "value" => "x" * (ArchiveConfig.SUMMARY_MAX + 1) } } }].each do |edits|
      expect { policy.update(selection, edits) }.to raise_error(Ao3Backup::Error)
    end
  end
end
