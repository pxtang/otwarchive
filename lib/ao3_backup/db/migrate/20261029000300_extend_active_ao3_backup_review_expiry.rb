class ExtendActiveAo3BackupReviewExpiry < ActiveRecord::Migration[8.1]
  class ReviewSession < ActiveRecord::Base
    self.table_name = "ao3_backup_import_sessions"
  end

  def up
    cutoff = Time.current
    ReviewSession.where("expires_at > ?", cutoff).where.not(state: %w[expired cancelled]).find_each do |session|
      extended = session.created_at + 1.week
      next unless session.expires_at < extended
      # The predicate prevents changing a session that expired or was otherwise
      # modified while this migration was processing the batch.
      ReviewSession.where(id: session.id, expires_at: session.expires_at).where.not(state: %w[expired cancelled]).where("expires_at > ?", Time.current).update_all(expires_at: extended)
    end
  end

  def down
    # Previous individual expiration times cannot be reconstructed safely.
  end
end
