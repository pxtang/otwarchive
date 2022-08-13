bundle exec rake After:sortable_tag_names
bundle exec rake Tag:reset_common
bundle exec rake Tag:reset_count
bundle exec rake Tag:reset_filters
echo "Going to sleep for 60 seconds, then run world_index_queue"
sleep 60 && bundle exec rake search:run_world_index_queue
bundle exec rake Tag:reset_filter_counts
bundle exec rake Tag:reset_meta_tags
bundle exec rake autocomplete:load_data

echo "Starting 4 indexing tasks"
bundle exec rake environment search:index_bookmarks
bundle exec rake environment search:index_pseuds
bundle exec rake environment search:index_tags
bundle exec rake environment search:index_works

echo "Starting resque works"
QUEUE="*" bundle exec rake environment resque:work &

echo "Starting resque scheduler"
nohup bundle exec rake resque:scheduler &