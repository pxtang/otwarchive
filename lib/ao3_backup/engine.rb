module Ao3Backup
  class Engine < ::Rails::Engine
    config.root = File.expand_path(__dir__)
    isolate_namespace Ao3Backup
    initializer "ao3_backup.migrations" do |app|
      app.config.paths["db/migrate"].concat(config.paths["db/migrate"].expanded)
    end
  end
end
