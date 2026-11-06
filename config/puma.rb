# typed: false

# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
# 8, not the Rails-default 3: like hub, most request time here is IO-wait
# (media proxying, upstream calls), and 3 threads made hub's pages queue behind
# slow proxies (comment ported from hub:config/puma.rb).
threads_count = ENV.fetch("RAILS_MAX_THREADS", 8)
threads threads_count, threads_count

# Worker processes (docs/PERF_PROPOSAL.md › P13): a segment request holds
# its thread while the transcoder makes the segment, so in production two
# processes share the load and a burst of seeks can't queue every API call
# behind it. fog routes one port to one process, so they share it here.
# Unset (development, specs) runs one process. Active Record reconnects in
# each forked worker by itself.
workers_count = ENV.fetch("WEB_CONCURRENCY", 0).to_i
if workers_count > 1
  workers workers_count
  preload_app!
end

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
