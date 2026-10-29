require "spec_helper"
require "capybara/rspec"
require "selenium-webdriver"
require "timeout"

RSpec.describe "Magic Import browser review", type: :feature do
  include MagicImportFixtures
  self.use_transactional_tests = false

  around do |example|
    previous_inline = Resque.inline
    previous_driver = Capybara.current_driver
    previous_host = Capybara.app_host
    DatabaseCleaner.strategy = :truncation
    Resque.inline = false
    Capybara.app = Rails.application
    Capybara.server = :webrick
    Capybara.server_host = "0.0.0.0"
    Capybara.server_port = ENV.fetch("CAPYBARA_PORT", "5100").to_i
    Capybara.app_host = "http://test:#{Capybara.server_port}"
    Capybara.default_max_wait_time = 15
    Capybara.register_driver :magic_import_chrome do |app|
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--headless")
      options.add_argument("--disable-site-isolation-trials")
      Capybara::Selenium::Driver.new(app, browser: :remote, url: ENV.fetch("CHROME_URL"), options: options)
    end
    Capybara.current_driver = :magic_import_chrome
    example.run
  ensure
    Capybara.reset_sessions!
    Capybara.current_driver = previous_driver
    Capybara.app_host = previous_host
    Resque.inline = previous_inline
    DatabaseCleaner.strategy = :transaction
  end

  it "uses real queued progress and native review controls without creating archive content" do
    owner = create(:user, password: "Preview-Test-Secret-42", password_confirmation: "Preview-Test-Secret-42")
    Skin.load_site_css
    Skin.set_default_to_current_version
    AdminSetting.default.update_attribute(:default_skin_id, Skin.default.id)
    load Rails.root.join("script/ensure_required_tags.rb")
    source_html = captured("10_12").html.sub("Invented prose chapter 1.", "Invented paragraph. " * 1500)
    source_html = source_html.sub("Work ending note.", '<b lang="fr">bonjour</b><abbr title="meaning" align="right">ABC</abbr>')
    source = captured(html: source_html)
    Fandom.create!(name: "呪術廻戦 | Jujutsu Kaisen (Anime)")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("AO3_BACKUP_ENABLED").and_return("true")
    allow(ENV).to receive(:[]).with("AO3_FLARESOLVERR_URL").and_return("http://solver.test:8191")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AO3_BACKUP_OWNER_IDS", "").and_return(owner.id.to_s)
    started, release = Queue.new, Queue.new
    stub_request(:post, "http://solver.test:8191/v1").to_return do
      started << true
      release.pop
      { status: 200, body: JSON.generate(status: "ok", solution: { status: 200, url: source.identity.fetch_url, response: source.html }) }
    end
    visit "/users/login"
    within("#loginform") do
      fill_in "user_login", with: owner.login
      fill_in "user_password", with: "Preview-Test-Secret-42"
      find('input[type="submit"]').click
    end
    visit "/backup_imports"
    expect(page).to have_css("h2", text: "Magic Import work")
    expect(page.evaluate_script("getComputedStyle(document.body).fontFamily")).to include("Lucida")
    new_work_url = find('#greeting a', text: 'New Work', visible: :all)[:href]
    expect(URI(new_work_url).path).to eq("/works/new")
    visit new_work_url
    expect(page).to have_field("work_title")
    expect(page).to have_select("work_rating_string", with_options: [ArchiveConfig.RATING_DEFAULT_TAG_NAME, ArchiveConfig.RATING_TEEN_TAG_NAME, ArchiveConfig.RATING_EXPLICIT_TAG_NAME])
    visit "/works/search"
    expect(page).to have_field("work_search_query")
    visit "/backup_imports"
    before_counts = [Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)
    fill_in "AO3 work or chapter URL", with: source.identity.canonical_url
    click_button "Fetch and inspect"
    expect(page).to have_content("Waiting to fetch")
    session = Ao3Backup::ImportSession.last
    queued = Resque.reserve(:utilities)
    expect(queued.payload["args"]).to eq([session.id, 1])
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { queued.perform }
    end
    Timeout.timeout(10) { started.pop }
    expect(page).to have_content("Fetching source work")
    release << true
    worker.value
    expect(page).to have_content("Exact proposed output")
    expect(page).to have_content("Source word count: 1,234")
    expect(page).to have_button("Save to archive (not enabled yet)", disabled: true)
    expect(page).to have_css('script[src="/javascripts/tinymce/tinymce.min.js"]', visible: :all)
    expect(page).to have_css('script[src="/javascripts/mce_editor.min.js"]', visible: :all)
    summary_editor = find('[data-editor-id="scalar_summary"]')
    page.execute_script("arguments[0].scrollIntoView({block: 'center'})", summary_editor)
    expect(page).to have_css("#scalar_summary_ifr")
    within_frame("scalar_summary_ifr") { expect(page).to have_content("Invented summary.") }
    summary_editor.find('[data-editor-mode="html"]').click
    expect(page).not_to have_css("#scalar_summary_ifr")
    fill_in "scalar_summary", with: "<p><strong>Edited rich summary</strong></p>"
    summary_editor.find('[data-editor-mode="rich"]').click
    expect(page).to have_css("#scalar_summary_ifr")
    within_frame("scalar_summary_ifr") { expect(page).to have_css("strong", text: "Edited rich summary") }
    page.save_screenshot(Rails.root.join("tmp/magic-import-rich-editor.png"))
    notes_editor = find('[data-editor-id="scalar_notes"]')
    page.execute_script("arguments[0].scrollIntoView({block: 'center'})", notes_editor)
    expect(page).to have_css("#scalar_notes_ifr")
    page.execute_script("tinyMCE.get('scalar_notes').setContent('<p><em>Edited rich notes</em></p>')")
    untouched_editor = find('[data-editor-id="scalar_endnotes"]')
    page.execute_script("arguments[0].scrollIntoView({block: 'center'})", untouched_editor)
    expect(page).to have_css("#scalar_endnotes_ifr")
    untouched_editor.find('[data-editor-mode="html"]').click
    expect(find_field("scalar_endnotes").value).to include('<b lang="fr">', '<abbr title="meaning" align="right">')
    untouched_editor.find('[data-editor-mode="rich"]').click
    expect(page).to have_css("#scalar_endnotes_ifr")
    chapter_notes = find('[data-editor-id="chapter_2_endnotes"]')
    page.execute_script("arguments[0].scrollIntoView({block: 'center'})", chapter_notes)
    expect(page).to have_css("#chapter_2_endnotes_ifr")
    page.execute_script("tinyMCE.get('chapter_2_endnotes').setContent('<p>Edited chapter endnotes</p>')")
    inspection = find("#inspect-chapter-1")
    inspection.find("summary").click
    scroller = inspection.find(".magic-chapter-scroll")
    expect(page.evaluate_script("arguments[0].scrollHeight > arguments[0].clientHeight", scroller)).to eq(true)
    page.execute_script("arguments[0].scrollTop = arguments[0].scrollHeight", scroller)
    expect(inspection.find("summary")).to be_visible
    inspection.click_button "Collapse chapter 1 body"
    expect(page.evaluate_script("arguments[0].open", inspection)).to eq(false)
    expect(page.evaluate_script("document.activeElement === document.querySelector('#inspect-chapter-1 > summary')")).to eq(true)
    expect(page.all("#magic-selection-form > fieldset").map { |section| section.find("legend").text }).to eq(["Tags", "Preface", "Associations", "Privacy", "Work Text"])
    within("#magic-preface") { expect(page).to have_field("scalar_title") }
    within("#magic-associations") do
      expect(page).to have_field("scalar_expected_chapters")
      expect(page).to have_field("scalar_language")
      expect(page).to have_content("no local series is created")
    end
    within("#magic-privacy") { expect(page).to have_content("not configured") }
    within("#magic-work-text") { expect(page).to have_css("#inspect-chapter-1") }
    groups = all("#magic-tags .magic-tag-group")
    expect(groups.map { |group| group.find("h4").text }).to eq(["Source authors", "Rating", "Archive Warnings", "Fandoms", "Categories", "Relationships", "Characters", "Additional Tags"])
    expect(find('[data-tag-group="author"]')).to have_css(".tag-candidate.author")
    expect(find('[data-tag-group="Rating"]')).to have_css('.tag-candidate[data-type="Rating"]')
    expect(find('[data-tag-group="Fandom"]')).to have_css('.tag-candidate[data-type="Fandom"]', count: 2)
    original_tag_order = session.reload.selection["tags"].map { |tag| tag["id"] }
    selection = session.reload.selection
    author_id = selection["tags"].find { |tag| tag["author"] }["id"]
    rating_id = selection["tags"].find { |tag| tag["type"] == "Rating" }["id"]
    expect(find("#tag_keep_#{author_id}")).to be_checked
    expect(find("#tag_keep_#{rating_id}")).not_to be_checked
    select "Fandom", from: "magic_tag_type"
    click_button "Clear visible"
    select "All types", from: "magic_tag_type"
    fill_in "magic_tag_search", with: "Invented"
    expect(page).to have_css(".tag-candidate", count: 5)
    fill_in "magic_tag_search", with: ""
    fill_in "scalar_title", with: "A locally reviewed title"
    fill_in "tag_name_#{author_id}", with: "Local_Author"
    uncheck "keep_summary"
    click_button "Update review"
    expect(page).to have_content("Review choices updated")
    expect(page).to have_content("Fetched: Invented_Author")
    within("#magic-proposed-output") do
      expect(page).to have_content("A locally reviewed title")
      expect(page).to have_content("Local_Author")
      expect(page).not_to have_content("Jujutsu Kaisen")
      expect(page).to have_content("Edited rich notes")
    end
    expect(session.reload.selection_revision).to eq(1)
    expect(session.selection["tags"].map { |tag| tag["id"] }).to eq(original_tag_order)
    expect(session.selection["tags"].first["author"]).to eq(true)
    expect(session.selection.dig("scalars", "notes", "value")).to include("Edited rich notes")
    expect(session.selection.dig("scalars", "endnotes", "value")).to include('<b lang="fr">', '<abbr title="meaning" align="right">')
    expect(session.selection.dig("scalars", "summary", "value")).to include("<strong>Edited rich summary</strong>")
    expect(session.selection.dig("scalars", "summary", "keep")).to eq(false)
    expect(session.selection.dig("chapters", 1, "fields", "endnotes", "value")).to include("Edited chapter endnotes")
    expect(session.selection["tags"].select { |tag| tag["type"] == "Fandom" }.map { |tag| tag["keep"] }).to eq([false, false])
    expect([Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)).to eq(before_counts)
    expect(a_request(:post, "http://solver.test:8191/v1")).to have_been_made.once
    page.current_window.resize_to(1440, 1000)
    page.execute_script("document.getElementById('magic-import-review').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/magic-import-review-desktop.png"))
    page.current_window.resize_to(390, 844)
    page.execute_script("document.getElementById('magic-import-review').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/magic-import-review-mobile.png"))
    visit "/backup_imports"
    expect(page).to have_content("A locally reviewed title")
    expect(page).to have_content("Invented_Author")
    dismiss_confirm("Delete this review and its temporary snapshot and choices?") { click_link "Delete" }
    expect(Ao3Backup::ImportSession.exists?(session.id)).to be true
    accept_confirm("Delete this review and its temporary snapshot and choices?") { click_link "Delete" }
    expect(page).to have_content("Review deleted")
    expect(Ao3Backup::ImportSession.exists?(session.id)).to be false
    expect(Ao3Backup::Snapshot.where(import_session_id: session.id)).to be_empty
    expect([Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)).to eq(before_counts)
  ensure
    release << true if release && worker&.alive?
    worker&.join(5)
  end
end
