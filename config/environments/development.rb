Otwarchive::Application.configure do
  # Settings specified here will take precedence over those in config/environment.rb

  memcache = true

  # In the development environment your application's code is reloaded on
  # every request.  This slows down response time but is perfect for development
  # since you don't have to restart the webserver when you make code changes.
  config.cache_classes = memcache
  config.eager_load = memcache
  # config.cache_classes = false
  # config.eager_load = false


  memcached_servers = "127.0.0.1:11211"
  memcached_servers = YAML.load_file(Rails.root.join("config/local.yml")).fetch("MEMCACHED_SERVERS", memcached_servers) if File.file?(Rails.root.join("config/local.yml"))
  config.cache_store = :mem_cache_store, memcached_servers,
                       { namespace: "ao3-v2-dev", compress: true, pool_size: 10 }

  # Log error messages when you accidentally call methods on nil.
  # config.whiny_nils = true

  # Show full error reports:
  config.consider_all_requests_local = true

  # Enable/disable caching. By default caching is disabled, but it can be
  # toggled on and off by calling rails dev:cache and restarting the server.
  # config.action_controller.perform_caching = Rails.root.join("tmp/caching-dev.txt").exist?
  config.action_controller.perform_caching = memcache

  # Don't care if the mailer can't send
  config.action_mailer.raise_delivery_errors = false

  # Print deprecation notices to the Rails logger
  config.active_support.deprecation = :log

  # Only use best-standards-support built into browsers
  config.action_dispatch.best_standards_support = :builtin

  # Don't make it clear we are on Dev. That's silly!
  config.rack_dev_mark.enable = false
  config.rack_dev_mark.theme = [:title, Rack::DevMark::Theme::GithubForkRibbon.new(position: "left", color: "green", fixed: "true")]

  # why is this set twice?
  # config.eager_load = false
  config.assets.enabled = false
  config.serve_static_files = true

  # Don't Enable Bullet gem to monitor application performance
  config.after_initialize do
    Bullet.enable = false
    Bullet.bullet_logger = true
    Bullet.console = true
    Bullet.add_footer = false
    Bullet.rails_logger = true
    Bullet.counter_cache_enable = false
  end

  # Allow all hostnames for dev env
  config.hosts.clear
end
