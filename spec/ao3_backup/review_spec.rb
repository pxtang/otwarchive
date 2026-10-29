require "spec_helper"

RSpec.describe "Magic Import review lifecycle" do
  include MagicImportFixtures
  let(:owner) { create(:user) }
  let(:now) { Time.utc(2026, 10, 28, 12) }
  let(:clock) { -> { now } }
  let(:dispatcher) { ->(_id, _generation) { true } }
  let(:service) { Ao3Backup::SessionService.new(clock: clock, dispatcher: dispatcher) }
  let(:session) { service.start(owner: owner, url: captured.identity.canonical_url) }
  let(:provider) { instance_double(Ao3Backup::Provider, call: captured) }
  let(:job) { Ao3Backup::FetchJob.new(provider: provider, clock: clock) }

  def counts
    [Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)
  end

  it "queues only the session ID and generation on the existing utilities queue" do
    previous_inline = Resque.inline
    Resque.inline = false
    session = Ao3Backup::SessionService.new(clock: clock).start(owner: owner, url: captured.identity.canonical_url)
    expect(Resque.peek(:utilities)).to include("class" => "Ao3Backup::FetchJob", "args" => [session.id, 1])
    expect(session.state).to eq("queued")
    expect(session.dispatch_pending).to eq(false)
  ensure
    Resque.inline = previous_inline
  end

  it "keeps durable queued intent when Redis dispatch fails and recovers without refetching" do
    failed = Ao3Backup::SessionService.new(clock: clock, dispatcher: ->(*) { raise Redis::CannotConnectError })
    session = failed.start(owner: owner, url: captured.identity.canonical_url)
    expect(session).to have_attributes(state: "queued", dispatch_pending: true, error_code: "dispatch_failed")
    service.dispatch(session)
    expect(session.reload).to have_attributes(state: "queued", dispatch_pending: false, generation: 1)
  end

  it "creates an immutable snapshot and editable selection without any content/tag writes" do
    session
    before_counts = counts
    job.call(session.id, 1)
    expect(session.reload).to have_attributes(state: "ready", selection_revision: 0, snapshot_digest: captured.digest)
    expect(counts).to eq(before_counts)
    snapshot = session.current_snapshot
    expect { snapshot.update!(digest: "different") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    service.update_selection(session, revision: 0, digest: captured.digest,
                             edits: { "tags" => [], "scalars" => { "summary" => { "keep" => false } } })
    expect(session.reload.selection_revision).to eq(1)
    expect(Ao3Backup::SelectionPolicy.new.proposed(session.selection)["tags"]).to eq([])
    expect(session.current_snapshot.reload.manifest).to eq(snapshot.manifest)
    expect(counts).to eq(before_counts)
  end

  it "does not copy temporary source metadata into SQL debug logs" do
    session
    output = StringIO.new
    previous_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(output)
    ActiveRecord::Base.logger.level = Logger::DEBUG
    job.call(session.id, 1)
    service.update_selection(session.reload, revision: 0, digest: captured.digest, edits: { "tags" => [] })
    expect(session.reload.state).to eq("ready")
    expect(output.string).not_to include("Invented prose", "Invented_Author", "Invented summary")
  ensure
    ActiveRecord::Base.logger = previous_logger
  end

  it "does not hold the session SQL lock or start another transaction during source I/O" do
    session
    outer = Work.connection.open_transactions
    expect(provider).to receive(:call) do
      expect(Work.connection.open_transactions).to eq(outer)
      captured
    end
    job.call(session.id, 1)
    expect(session.reload.state).to eq("ready")
  end

  it "ignores duplicate deliveries and rejects stale selection revision or digest" do
    job.call(session.id, 1)
    expect(provider).not_to receive(:call)
    job.call(session.id, 1)
    [[1, captured.digest], [0, "wrong"], ["invalid", captured.digest]].each do |revision, digest|
      expect { service.update_selection(session, revision: revision, digest: digest, edits: {}) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("stale_revision") }
    end
    expect(session.reload.selection_revision).to eq(0)
  end

  it "creates a new retry generation and prevents the late first fetch from overwriting it" do
    session
    expect(provider).to receive(:call) do
      service.retry_fetch(session)
      captured
    end
    job.call(session.id, 1)
    expect(session.reload).to have_attributes(state: "queued", generation: 2, snapshot_digest: nil)
    expect(session.snapshots.count).to eq(0)
    Ao3Backup::FetchJob.new(provider: instance_double(Ao3Backup::Provider, call: captured), clock: clock).call(session.id, 2)
    expect(session.reload).to have_attributes(state: "ready", generation: 2)
  end

  it "does not allow late fetches to overwrite cancellation or expiration" do
    session
    expect(provider).to receive(:call) do
      service.cancel(session)
      captured
    end
    job.call(session.id, 1)
    expect(session.reload).to have_attributes(state: "cancelled", selection: nil, snapshot_digest: nil)
    expect(session.snapshots.count).to eq(0)
  end

  it "extends only still-active legacy sessions during migration" do
    require Rails.root.join("lib/ao3_backup/db/migrate/20261029000300_extend_active_ao3_backup_review_expiry")
    current = Time.current
    active = service.start(owner: owner, url: captured.identity.canonical_url)
    expired = service.start(owner: owner, url: captured.identity.canonical_url)
    cancelled = service.start(owner: owner, url: captured.identity.canonical_url)
    [active, expired, cancelled].each { |item| item.update_columns(created_at: current - 12.hours, expires_at: current + 12.hours) }
    expired.update_columns(expires_at: current - 1.second)
    cancelled.update_columns(state: "cancelled")
    old_expired = expired.expires_at
    old_cancelled = cancelled.expires_at
    ExtendActiveAo3BackupReviewExpiry.new.up
    expect(active.reload.expires_at).to be_within(1.second).of(active.created_at + 1.week)
    expect(expired.reload.expires_at).to eq(old_expired)
    expect(cancelled.reload.expires_at).to eq(old_cancelled)
  end

  it "sets a one-week expiry for new sessions using the injected clock" do
    expect(session.expires_at).to eq(now + 1.week)
    job.call(session.id, 1)
    Ao3Backup::SessionService.new(clock: -> { now + 1.week - 1.second }).expire(session)
    expect(session.reload.state).to eq("ready")
    Ao3Backup::SessionService.new(clock: -> { now + 1.week }).expire(session)
    expect(session.reload.state).to eq("expired")
    expect(session.snapshots.count).to eq(0)
  end

  it "ignores deleted queued and in-flight jobs, including failed fetches" do
    id = session.id
    before_counts = counts
    expect(provider).to receive(:call) { session.destroy!; captured }
    expect { job.call(id, 1) }.not_to raise_error
    expect { job.call(id, 1) }.not_to raise_error
    expect(Ao3Backup::ImportSession.find_by(id: id)).to be_nil
    expect(Ao3Backup::Snapshot.where(import_session_id: id)).to be_empty
    expect(counts).to eq(before_counts)
    second = service.start(owner: owner, url: captured.identity.canonical_url)
    failing = instance_double(Ao3Backup::Provider)
    expect(failing).to receive(:call) { second.destroy!; raise "fetch failed" }
    expect { Ao3Backup::FetchJob.new(provider: failing, clock: clock).call(second.id, 1) }.not_to raise_error
  end

  it "records missing records from the provider or parser as fetch failures" do
    ["provider", "parser"].each do |stage|
      current = service.start(owner: owner, url: captured.identity.canonical_url)
      failing_provider = instance_double(Ao3Backup::Provider)
      failing_parser = instance_double(Ao3Backup::Parser)
      if stage == "provider"
        allow(failing_provider).to receive(:call).and_raise(ActiveRecord::RecordNotFound)
      else
        allow(failing_provider).to receive(:call).and_return(captured)
        allow(failing_parser).to receive(:call).and_raise(ActiveRecord::RecordNotFound)
      end
      expect { Ao3Backup::FetchJob.new(provider: failing_provider, parser: failing_parser, clock: clock).call(current.id, 1) }.not_to raise_error
      expect(current.reload).to have_attributes(state: "fetch_failed", error_code: "fetch_failed")
    end
  end

  it "expires at the injected boundary and removes temporary snapshot and choices" do
    job.call(session.id, 1)
    expiry = Ao3Backup::SessionService.new(clock: -> { session.expires_at })
    expiry.expire(session)
    expect(session.reload).to have_attributes(state: "expired", selection: nil, snapshot_digest: nil)
    expect(session.snapshots.count).to eq(0)
    expect { expiry.update_selection(session, revision: 0, digest: captured.digest, edits: {}) }.to raise_error(Ao3Backup::Error)
  end

  it "discards a fetch that crosses its expiration time" do
    session
    ticks = [now, session.expires_at, session.expires_at, session.expires_at]
    crossing_clock = -> { ticks.shift || session.expires_at }
    Ao3Backup::FetchJob.new(provider: provider, clock: crossing_clock).call(session.id, 1)
    expect(session.reload).to have_attributes(state: "expired", selection: nil)
    expect(session.snapshots.count).to eq(0)
  end

  it "records useful typed errors, restores current user, and bounds explicit fetch retries" do
    session
    previous = create(:user)
    User.current_user = previous
    allow(provider).to receive(:call).and_raise(Ao3Backup::Error.new(:target_rate_limited, "Wait before retrying.", retry_after: "60"))
    job.call(session.id, 1)
    expect(session.reload).to have_attributes(state: "fetch_failed", error_code: "target_rate_limited", retry_after: "60")
    expect(User.current_user).to eq(previous)
    expect { service.retry_fetch(session) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("retry_later") }
    later = Ao3Backup::SessionService.new(clock: -> { now + 61.seconds }, dispatcher: dispatcher)
    later.retry_fetch(session)
    later.retry_fetch(session)
    expect { later.retry_fetch(session) }.to raise_error(Ao3Backup::Error) { |error| expect(error.code).to eq("retry_limit") }
  end
end

RSpec.describe "Magic Import review requests", type: :request do
  include MagicImportFixtures
  let(:owner) { create(:user) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("AO3_BACKUP_ENABLED").and_return("true")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AO3_BACKUP_OWNER_IDS", "").and_return(owner.id.to_s)
    sign_in owner
    cookies[:user_credentials] = "1"
  end

  def ready_session
    session = Ao3Backup::SessionService.new(dispatcher: ->(*) { true }).start(owner: owner, url: captured.identity.canonical_url)
    Ao3Backup::FetchJob.new(provider: instance_double(Ao3Backup::Provider, call: captured)).call(session.id, 1)
    session.reload
  end

  it "renders the native entry and third Post menu link with no content save action" do
    get "/backup_imports"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Magic Import work", "Fetch and inspect", "saving to the archive is not enabled")
    document = Nokogiri::HTML5.parse(response.body)
    post_menu = document.css("#greeting .dropdown .menu").find { |menu| menu.text.include?("New Work") }
    expect(post_menu.css("li a").first(3).map(&:text)).to eq(["New Work", "Import Work", "Magic Import work"])
  end

  it "renders exact choices and persists manual deselections across edit round trips without content writes" do
    session = ready_session
    before_counts = [Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)
    get "/backup_imports/import_sessions/#{session.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Exact proposed output", "Save to archive (not enabled yet)")
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: session.snapshot_digest, selection: { tags: [], scalars: { summary: { keep: "0" } } }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:found)
    follow_redirect!
    expect(response.body).to include("No tags selected.")
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 1, digest: session.snapshot_digest, selection: { scalars: { title: { value: "Locally edited title" } } }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    follow_redirect!
    expect(response.body).to include("Locally edited title", "No tags selected.")
    expect([Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)).to eq(before_counts)
    expect(session.reload.selection_revision).to eq(2)
  end

  it "supports the New Work layout and preserves its choices across layouts without content writes" do
    load Rails.root.join("script/ensure_required_tags.rb")
    session = ready_session
    rating = Rating.defaults_by_severity.first
    warning = ArchiveWarning.canonical.by_name.first
    expect(rating).to be_present
    expect(warning).to be_present
    counts = [Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)
    get "/backup_imports/import_sessions/#{session.id}?layout=new_work"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("New Work layout", "Add a fandom", rating.name, warning.name)
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: session.snapshot_digest, layout: "new_work", selection: { scalars: {} }, additional_tags: { Rating: [rating.name], ArchiveWarning: [warning.name], Fandom: ["A review fandom"] }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:found)
    expect(session.reload.selection["tags"].select { |tag| tag["keep"] }.map { |tag| tag["name"] }).to include(rating.name, warning.name, "A review fandom")
    get "/backup_imports/import_sessions/#{session.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("A review fandom")
    expect([Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)).to eq(counts)
  end

  it "requires a rating, warning and fandom on alternate review update" do
    session = ready_session
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: session.snapshot_digest, layout: "new_work", selection: { scalars: {} }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Choose at least one rating")
    expect(session.reload.selection_revision).to eq(0)
  end

  it "preserves multiple ratings and a case-variant local tag when switching layouts" do
    load Rails.root.join("script/ensure_required_tags.rb")
    session = ready_session
    ratings = Rating.defaults_by_severity.compact.first(2)
    warning = ArchiveWarning.canonical.by_name.first
    initial = session.selection
    initial["tags"] += ratings.each_with_index.map { |rating, i| Ao3Backup::LocalTagResolver.new.call("id" => "rating-#{i}", "name" => rating.name, "type" => "Rating", "keep" => true, "author" => false) }
    initial["tags"] << Ao3Backup::LocalTagResolver.new.call("id" => "case-warning", "name" => warning.name.swapcase, "type" => "ArchiveWarning", "keep" => true, "author" => false)
    session.update!(selection: initial)
    get "/backup_imports/import_sessions/#{session.id}?layout=new_work"
    doc = Nokogiri::HTML5.parse(response.body)
    expect(doc.at_css('#extra_rating-1[checked]')).to be_present
    expect(doc.at_css("#choice_#{warning.id}[checked]")).to be_present
    tags = initial["tags"].map { |tag| tag.slice("id", "name", "keep").merge("keep" => %w[Rating ArchiveWarning].include?(tag["type"]) ? (tag["id"] == "rating-1" ? "1" : "0") : (tag["keep"] ? "1" : "0")) }
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: session.snapshot_digest, layout: "new_work", switch_layout: "review", selection: { tags: tags }, additional_tags: { Rating: [ratings.first.name], ArchiveWarning: [warning.name] }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:found)
    result = session.reload.selection["tags"]
    expect(result.select { |tag| tag["type"] == "Rating" && tag["keep"] }.map { |tag| tag["local_id"] }).to include(*ratings.map(&:id))
    expect(result.find { |tag| tag["id"] == "case-warning" }["keep"]).to be true
  end

  it "retains rejected edits safely without changing the saved selection or proposed output" do
    session = ready_session
    saved = session.selection
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: session.snapshot_digest, layout: "new_work", selection: { scalars: { title: { keep: "0", replacement: "" }, summary: { keep: "1", value: "<p>Edited summary</p><script>bad()</script>" } } }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:unprocessable_entity)
    doc = Nokogiri::HTML5.parse(response.body)
    expect(doc.at_css('#scalar_summary').text).to include('Edited summary')
    expect(doc.at_css('#scalar_summary').text).not_to include('<script>')
    expect(doc.at_css('#keep_title')).not_to have_attribute('checked')
    expect(doc.at_css('#magic-proposed-output').text).not_to include('Edited summary')
    expect(session.reload.selection).to eq(saved)
  end

  it "preserves allowed rich formatting and strips unsafe markup in review edits" do
    session = ready_session
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(
      revision: 0, digest: session.snapshot_digest,
      selection: { scalars: { summary: { value: '<p><strong>Bold</strong><script>alert(1)</script></p>' } },
                   chapters: { "1" => { notes: { value: '<p><em>Chapter note</em></p>' } } } }
    ), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:found)
    selection = session.reload.selection
    expect(selection.dig("scalars", "summary", "value")).to include("<strong>Bold</strong>")
    expect(selection.dig("scalars", "summary", "value")).not_to include("<script>", "alert(1)")
    expect(selection.dig("chapters", 0, "fields", "notes", "value")).to include("<em>Chapter note</em>")
  end

  it "rejects another owner's session at every read/edit/control route" do
    other = create(:user)
    session = Ao3Backup::SessionService.new(dispatcher: ->(*) { true }).start(owner: other, url: captured.identity.canonical_url)
    get "/backup_imports/import_sessions/#{session.id}.json"
    expect(response).to have_http_status(:not_found)
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(selection: { tags: [] }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:not_found)
    %w[cancel retry_fetch recover_dispatch].each do |action|
      post "/backup_imports/import_sessions/#{session.id}/#{action}"
      expect(response).to have_http_status(:not_found)
    end
    expect(session.reload.state).to eq("queued")
  end

  it "rejects stale and malformed edits while preserving the ready review" do
    session = ready_session
    [{ revision: 10, digest: session.snapshot_digest, selection: { tags: [] } },
     { revision: 0, digest: session.snapshot_digest, selection: { chapters: { "1" => { content: { keep: false } } } } },
     { revision: 0, digest: session.snapshot_digest, selection: { scalars: { title: { keep: "0" } } } }].each do |edits|
      patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(edits), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(session.reload.selection_revision).to eq(0)
  end

  it "returns rejected edits rather than server errors for malformed nested selections" do
    session = ready_session
    ["bad", { scalars: "bad" }, { chapters: "bad" }, { tags: [1] },
     { tags: [{ id: nil, keep: false }] }, { scalars: { title: [] } },
     { chapters: { "1" => [] } }].each do |selection|
      patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: session.snapshot_digest, selection: selection), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(session.reload.selection_revision).to eq(0)
  end

  it "rejects an omitted tag keep choice without altering the revision, snapshot or archive" do
    session = ready_session
    before_counts = [Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)
    digest = session.snapshot_digest
    snapshot = session.current_snapshot.manifest
    tags = session.selection["tags"].map { |tag| tag.slice("id", "name", "keep") }
    tags.first.delete("keep")
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: digest, selection: { tags: tags }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Every tag choice must include an explicit keep boolean")
    expect(session.reload).to have_attributes(selection_revision: 0, snapshot_digest: digest, state: "ready")
    expect(session.current_snapshot.reload.manifest).to eq(snapshot)
    expect([Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)).to eq(before_counts)
  end

  it "shows ready titles and authors, and clears expired details before listing" do
    session = ready_session
    get "/backup_imports"
    expect(response.body).to include("Source author", "Invented_Author", session.selection.dig("scalars", "title", "value"))
    session.update!(expires_at: 1.second.ago)
    get "/backup_imports"
    expect(response.body).not_to include("Invented_Author")
    expect(response.body).to include("Expired", "AO3 work #{session.source_work_id}")
    expect(session.reload.selection).to be_nil
    expect(session.snapshots.count).to eq(0)
  end

  it "deletes only the owner's review and its temporary data" do
    session = ready_session
    other = create(:user)
    foreign = Ao3Backup::SessionService.new(dispatcher: ->(*) { true }).start(owner: other, url: captured.identity.canonical_url)
    counts = [Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)
    get "/backup_imports/import_sessions/#{foreign.id}/confirm_delete"
    expect(response).to have_http_status(:not_found)
    delete "/backup_imports/import_sessions/#{foreign.id}"
    expect(response).to have_http_status(:not_found)
    get "/backup_imports/import_sessions/#{session.id}/confirm_delete"
    expect(response.body).to include("Delete review?", "Keep review")
    delete "/backup_imports/import_sessions/#{session.id}"
    expect(response).to have_http_status(:found)
    expect(Ao3Backup::ImportSession.find_by(id: session.id)).to be_nil
    expect(Ao3Backup::Snapshot.where(import_session_id: session.id)).to be_empty
    expect(Ao3Backup::ImportSession.exists?(foreign.id)).to be true
    expect([Work, Chapter, Tag, Tagging, Creatorship, Series].map(&:count)).to eq(counts)
  end

  it "enforces CSRF on deletion" do
    session = ready_session
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    delete "/backup_imports/import_sessions/#{session.id}"
    expect(response).to redirect_to("/auth_error")
    expect(Ao3Backup::ImportSession.exists?(session.id)).to be true
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it "enforces CSRF on mutations when protection is enabled" do
    session = ready_session
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    patch "/backup_imports/import_sessions/#{session.id}", params: JSON.generate(revision: 0, digest: session.snapshot_digest, selection: { tags: [] }), headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "text/html" }
    expect(response).to redirect_to("/auth_error")
    expect(session.reload.selection_revision).to eq(0)
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end

RSpec.describe "Archive forms beside Magic Import", type: :request do
  before do
    load Rails.root.join("script/ensure_required_tags.rb")
    Language.default
    sign_in create(:user)
    cookies[:user_credentials] = "1"
  end

  it "loads ordinary New Work and search with the required reference catalog and no draft creation" do
    counts = [Work.count, Chapter.count, Ao3Backup::Import.count]
    get "/works/new"
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML5.parse(response.body)
    expect(document.css("#work_rating_string option").map(&:text)).to include(ArchiveConfig.RATING_DEFAULT_TAG_NAME, ArchiveConfig.RATING_TEEN_TAG_NAME, ArchiveConfig.RATING_EXPLICIT_TAG_NAME)
    expect(response.body).to include("/javascripts/tinymce/tinymce.min.js", "/javascripts/mce_editor.min.js")
    get "/works/search"
    expect(response).to have_http_status(:ok)
    expect([Work.count, Chapter.count, Ao3Backup::Import.count]).to eq(counts)
  end
end
