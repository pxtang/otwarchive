require "spec_helper"

RSpec.describe Ao3Backup::CommitService do
  let(:owner) { create(:user) }
  let(:language) { create(:language) }
  let(:identity) do
    { source_host: "archiveofourown.org", source_work_id: "12345",
      canonical_url: "https://archiveofourown.org/works/12345",
      retrieved_at: Time.current, snapshot_digest: "a" * 64 }
  end
  let(:payload) do
    { work: { title: "An invented archival work", language_id: language.id,
              expected_number_of_chapters: nil, backdate: true },
      chapters: [{ content: "Invented opening chapter text.", published_at: Date.yesterday },
                 { content: "Invented second chapter text.", published_at: Date.current }] }
  end

  def save_backup
    described_class.new.call(payload: payload, identity: identity, owner: owner, pseud: owner.default_pseud)
  end

  it "saves durable optional metadata rules, posted chapters and archival creatorships through a later edit" do
    work = save_backup.reload
    expect(work).to be_posted
    expect(work).not_to be_restricted
    expect(work).not_to be_complete
    expect(work.expected_number_of_chapters).to be_nil
    expect(work.tags).to be_empty
    expect(work.pseuds).to eq([owner.default_pseud])
    expect(work.chapters.order(:position).pluck(:posted)).to eq([true, true])
    expect(work.chapters.flat_map { |chapter| chapter.pseuds.to_a }).to eq([owner.default_pseud] * 2)
    expect(work.chapters.order(:position).first.published_at.to_date).to eq(Date.yesterday)
    expect(work.ao3_backup_import).to be_persisted
    work.update!(title: "A locally edited archival work")
    expect(work.reload).to be_valid
    expect(ExternalAuthor.count).to eq(0)
    expect(ExternalCreatorship.count).to eq(0)
  end

  it "recognizes the built marker before validation but retains ordinary work requirements" do
    ordinary = Work.new(title: "An ordinary work", language: language)
    ordinary.creatorships.build(pseud: owner.default_pseud)
    expect(ordinary).not_to be_valid
    expect(ordinary.errors.attribute_names).to include(:fandom_string, :rating_string, :archive_warning_string)
    ordinary.build_ao3_backup_import(identity.merge(owner: owner))
    ordinary.valid?
    expect(ordinary.errors.attribute_names).not_to include(:fandom_string, :rating_string, :archive_warning_string)
  end

  it "rolls back every SQL object and restores current user after a late chapter failure" do
    owner
    language
    previous_user = create(:user)
    User.current_user = previous_user
    before_counts = [Work, Chapter, Tag, Tagging, Creatorship, Series, Ao3Backup::Import].map(&:count)
    allow_any_instance_of(Chapter).to receive(:save!).and_wrap_original do |method, *args|
      raise ActiveRecord::RecordInvalid, method.receiver if method.receiver.position == 2
      method.call(*args)
    end
    expect { save_backup }.to raise_error(ActiveRecord::RecordInvalid)
    expect([Work, Chapter, Tag, Tagging, Creatorship, Series, Ao3Backup::Import].map(&:count)).to eq(before_counts)
    expect(User.current_user).to eq(previous_user)
  end

  it "does not publish the work ID to Redis before the outer SQL transaction commits" do
    # The host suite's outer transaction rolls back. Related existing-pseud
    # refresh queues and harmless cache invalidations remain real callbacks.
    Work.transaction(requires_new: true) do
      work = save_backup
      expect(IndexQueue.from_class_and_label(Work, :main).ids).not_to include(work.id.to_s)
      expect(work.ao3_backup_import.publication_state).to eq("pending")
    end
  end

  context "with actual SQL commits" do
    self.use_transactional_tests = false
    around do |example|
      DatabaseCleaner.strategy = :truncation
      example.run
    ensure
      DatabaseCleaner.strategy = :transaction
    end

    it "publishes only committed work IDs with real callbacks and Redis" do
      work = nil
      Work.transaction do
        work = save_backup
        expect(IndexQueue.from_class_and_label(Work, :main).ids).not_to include(work.id.to_s)
      end
      expect(IndexQueue.from_class_and_label(Work, :main).ids).to include(work.id.to_s)
      expect(work.reload.ao3_backup_import).to be_persisted
    end

    it "keeps standalone repair indexing functional outside transactions" do
      work = save_backup
      IndexQueue::REDIS.del(IndexQueue.get_key(Work, :main))
      expect(Work.connection.transaction_open?).to eq(false)
      work.enqueue_to_index
      expect(IndexQueue.from_class_and_label(Work, :main).ids).to include(work.id.to_s)
    end

    it "publishes related-creatorship changes after commit" do
      work = save_backup
      extra_pseud = create(:pseud, user: owner)
      IndexQueue::REDIS.del(IndexQueue.get_key(Work, :main))
      work.creatorships.create!(pseud: extra_pseud)
      expect(IndexQueue.from_class_and_label(Work, :main).ids).to include(work.id.to_s)
    end

    it "queues destroyed imported works for search document removal" do
      work = save_backup
      id = work.id
      IndexQueue::REDIS.del(IndexQueue.get_key(Work, :main))
      work.destroy!
      expect(Work.exists?(id)).to eq(false)
      expect(IndexQueue.from_class_and_label(Work, :main).ids).to include(id.to_s)
    end

    it "never publishes a rolled-back work ID" do
      work = nil
      Work.transaction do
        work = save_backup
        raise ActiveRecord::Rollback
      end
      expect(Work.exists?(work.id)).to eq(false)
      expect(IndexQueue.from_class_and_label(Work, :main).ids).not_to include(work.id.to_s)
    end
  end

  it "restores current user after success and rejects another account's pseud" do
    previous_user = create(:user)
    User.current_user = previous_user
    save_backup
    expect(User.current_user).to eq(previous_user)
    expect do
      described_class.new.call(payload: payload, identity: identity, owner: owner, pseud: previous_user.default_pseud)
    end.to raise_error(ArgumentError)
    expect(User.current_user).to eq(previous_user)
  end
end

RSpec.describe "Magic Import foundation", type: :request do
  it "requires authentication for its entry route" do
    get "/backup_imports"
    expect(response).to redirect_to(new_user_session_path)
  end

  it "rejects authenticated accounts without explicit owner authorization" do
    sign_in create(:user)
    cookies[:user_credentials] = "1"
    get "/backup_imports"
    expect(response).to have_http_status(:forbidden)
  end
end
