bundle exec rake After:sortable_tag_names
bundle exec rake Tag:reset_common
bundle exec rake Tag:reset_count
bundle exec rake Tag:reset_filters
sleep 60 && bundle exec rake search:run_world_index_queue
bundle exec rake Tag:reset_filter_counts
bundle exec rake Tag:reset_meta_tags
bundle exec rake autocomplete:load_data
bundle exec rake environment search:index_bookmarks
bundle exec rake environment search:index_pseuds
bundle exec rake environment search:index_tags
bundle exec rake environment search:index_works
QUEUE="*" bundle exec rake environment resque:work