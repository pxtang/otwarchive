module Ao3Backup
  class ImportsController < ::ApplicationController
    before_action :authenticate_user!
    before_action :authorize_importer!

    def index
      render plain: "Magic Import work foundation. Review UI is not enabled yet."
    end

    private

    def authorize_importer!
      head :forbidden unless ENV["AO3_BACKUP_ENABLED"] == "true" &&
                             ENV.fetch("AO3_BACKUP_OWNER_IDS", "").split(",").include?(current_user.id.to_s)
    end
  end
end
