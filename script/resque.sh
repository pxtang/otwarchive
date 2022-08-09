bundle exec rake environment search:index_bookmarks
bundle exec rake environment search:index_pseuds
bundle exec rake environment search:index_tags
bundle exec rake environment search:index_works
echo "resque starting!"
QUEUE="*" bundle exec rake environment resque:work