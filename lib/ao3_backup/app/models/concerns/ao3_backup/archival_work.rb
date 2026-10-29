module Ao3Backup
  module ArchivalWork
    extend ActiveSupport::Concern

    included do
      has_one :ao3_backup_import, class_name: "Ao3Backup::Import", inverse_of: :work,
                               autosave: true, dependent: :destroy
    end

    def archival_backup?
      ao3_backup_import.present? && !ao3_backup_import.marked_for_destruction?
    end

    # Searchable normally publishes in after_save. New archival work IDs must
    # not be visible to an index worker until their SQL transaction commits.
    def enqueue_to_index
      return super unless archival_backup? && self.class.connection.transaction_open?

      # Attach to this transaction rather than a model save callback: callers
      # include related-record callbacks and after_destroy, and standalone repair
      # calls must still enqueue immediately. Rails discards this block on rollback.
      self.class.current_transaction.after_commit { publish_archival_backup_index }
    end

    private

    def publish_archival_backup_index
      IndexQueue.enqueue(self, :main)
    rescue StandardError => error
      # Provenance retains pending publication for M3's repair path. The saved
      # work remains the result even when Redis is unavailable after commit.
      Rails.logger.error("Magic Import index dispatch failed: #{error.class}")
    end
  end
end
