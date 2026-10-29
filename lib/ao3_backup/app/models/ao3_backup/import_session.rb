module Ao3Backup
  class ImportSession < ::ApplicationRecord
    self.table_name = "ao3_backup_import_sessions"
    attribute :selection, :json
    self.filter_attributes += [:selection]
    STATES = %w[queued fetching ready fetch_failed expired cancelled].freeze
    belongs_to :owner, class_name: "User"
    has_many :snapshots, dependent: :delete_all, inverse_of: :import_session
    validates :state, inclusion: { in: STATES }
    validates :source_host, :source_work_id, :canonical_url, :expires_at, presence: true

    def current_snapshot
      snapshots.find_by(generation: generation, digest: snapshot_digest)
    end
  end
end
