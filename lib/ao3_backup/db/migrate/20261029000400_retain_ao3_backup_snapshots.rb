class RetainAo3BackupSnapshots < ActiveRecord::Migration[8.1]
  def up
    change_column_null :ao3_backup_import_sessions, :expires_at, true
    execute "UPDATE ao3_backup_import_sessions SET expires_at = NULL"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Restoring automatic expiration would risk deleting cached snapshots"
  end
end
