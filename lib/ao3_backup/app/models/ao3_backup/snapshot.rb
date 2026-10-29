module Ao3Backup
  class Snapshot < ::ApplicationRecord
    self.table_name = "ao3_backup_snapshots"
    attribute :manifest, :json
    self.filter_attributes += [:manifest]
    belongs_to :import_session, inverse_of: :snapshots
    validates :digest, :manifest, :retrieved_at, presence: true
    before_update { raise ActiveRecord::ReadOnlyRecord, "Source snapshots are immutable" }
  end
end
