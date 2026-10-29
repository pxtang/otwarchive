class AddRetryTimeToAo3BackupSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :ao3_backup_import_sessions, :retry_not_before, :datetime
  end
end
