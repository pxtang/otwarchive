module Ao3Backup
  # Durable technical provenance, never a copy of rejected source metadata.
  class Import < ::ApplicationRecord
    self.table_name = "ao3_backup_imports"
    %w[chapter_map selected_policy tag_order].each { |field| attribute field, :json }
    belongs_to :work, inverse_of: :ao3_backup_import
    belongs_to :owner, class_name: "User"
    validates :source_host, :source_work_id, :canonical_url, :retrieved_at, :snapshot_digest, presence: true
    validates :source_work_id, uniqueness: { scope: :source_host }
  end
end
