# We deliberately declare only "web".  Background jobs run inside Puma,
# using solid_queue via "plugin :solid_queue" in config/puma.rb, which is
# enabled by setting SOLID_QUEUE_IN_PUMA=true.  So we do NOT need, and do
# not want, a separate "worker" dyno.
#
# Beware: if a process type isn't in this file, Heroku's Ruby buildpack
# still supplies a default command for it, and its default for "worker"
# is "bundle exec rake jobs:work" (a Delayed Job convention we don't use).
# We ran a worker dyno for a long time because of that.  It ran a
# do-nothing stub task, exited immediately, and Heroku kept restarting
# it, so we paid for a dyno to crash-loop while a permanently red line
# sat in "heroku ps" and taught us to ignore that display.  Both tiers
# are now scaled with "heroku ps:scale worker=0".  Don't scale one up
# again unless you also give it a real command here.
#
# If you ever *do* want jobs off the web dyno, so they stop competing
# with request handling for CPU and memory, add an explicit line such as
#   worker: bundle exec rake solid_queue:start
# and turn SOLID_QUEUE_IN_PUMA off.  solid_queue coordinates through the
# database, so it won't run a job twice, but there's no reason to have
# two configurations to keep in step unless we need the separation.
web: ./ignore-termerr env BUNDLE_DISABLE_EXEC_LOAD=true bundle exec puma -C config/puma.rb
