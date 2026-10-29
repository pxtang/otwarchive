class CreateAo3BackupImports < ActiveRecord::Migration[8.1]
  def change
    create_table :ao3_backup_imports do |t|
      t.integer :work_id, null: false
      t.integer :owner_id, null: false
      t.string :source_host, null: false
      t.string :source_work_id, null: false
      t.string :canonical_url, limit: 2080, null: false
      t.string :snapshot_digest, null: false
      t.datetime :retrieved_at, null: false
      t.string :publication_state, null: false, default: "pending"
      t.json :chapter_map
      t.json :selected_policy
      t.json :tag_order
      t.timestamps
    end
    add_index :ao3_backup_imports, [:source_host, :source_work_id], unique: true, name: "ao3_backup_source_identity"
    add_index :ao3_backup_imports, :work_id, unique: true
    add_foreign_key :ao3_backup_imports, :works
    add_foreign_key :ao3_backup_imports, :users, column: :owner_id
  end
end
