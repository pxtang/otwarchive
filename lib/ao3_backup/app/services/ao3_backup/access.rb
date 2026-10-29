module Ao3Backup
  class Access
    def self.allowed?(user)
      user.is_a?(User) && !user.banned? && !user.suspended? &&
        ENV["AO3_BACKUP_ENABLED"] == "true" &&
        ENV.fetch("AO3_BACKUP_OWNER_IDS", "").split(",").map(&:strip).include?(user.id.to_s)
    end
  end
end
