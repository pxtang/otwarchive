class CreateAo3BackupReviewSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :ao3_backup_import_sessions do |t|
      t.integer :owner_id, null: false
      t.string :source_host, null: false
      t.string :source_work_id, null: false
      t.string :canonical_url, limit: 2080, null: false
      t.string :state, null: false, default: "queued"
      t.integer :generation, null: false, default: 1
      t.integer :selection_revision, null: false, default: 0
      t.json :selection
      t.string :snapshot_digest
      t.datetime :expires_at, null: false
      t.boolean :dispatch_pending, null: false, default: true
      t.string :error_code
      t.string :error_message
      t.string :retry_after
      t.timestamps
    end
    add_index :ao3_backup_import_sessions, [:owner_id, :created_at], name: "ao3_backup_sessions_owner"
    add_foreign_key :ao3_backup_import_sessions, :users, column: :owner_id
    create_table :ao3_backup_snapshots do |t|
      t.bigint :import_session_id, null: false
      t.integer :generation, null: false
      t.string :digest, null: false
      t.json :manifest, null: false
      t.datetime :retrieved_at, null: false
      t.timestamps
    end
    add_index :ao3_backup_snapshots, [:import_session_id, :generation], unique: true, name: "ao3_backup_snapshot_generation"
    add_foreign_key :ao3_backup_snapshots, :ao3_backup_import_sessions, column: :import_session_id
  end
end
