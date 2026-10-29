module Ao3Backup
  # Internal save contract. No HTTP endpoint invokes this before M3.
  # Accepts only the final selected local values, not a source manifest.
  class CommitService
    def call(payload:, identity:, owner:, pseud:)
      previous_user = User.current_user
      raise ArgumentError, "Archival pseud must belong to owner" unless pseud.user_id == owner.id
      User.current_user = owner
      Work.transaction do
        work = Work.new(payload.fetch(:work).slice(:title, :summary, :notes, :endnotes,
                                                  :language_id, :expected_number_of_chapters, :backdate))
        work.posted = true
        work.restricted = false
        work.creatorships.build(pseud: pseud)
        work.build_ao3_backup_import(identity.merge(owner: owner))
        payload.fetch(:chapters).each_with_index do |attributes, index|
          chapter = work.chapters.build(attributes.slice(:title, :content, :summary, :notes, :endnotes, :published_at))
          chapter.position = index + 1
          chapter.posted = true
          chapter.creatorships.build(pseud: pseud)
        end
        work.save!
        work.chapters.each(&:save!)
        work.update_complete_status
        work
      end
    ensure
      User.current_user = previous_user if defined?(previous_user)
    end
  end
end
