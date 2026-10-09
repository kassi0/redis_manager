threads_count = ENV.fetch("PUMA_THREADS", 5).to_i
threads threads_count, threads_count

port ENV.fetch("PORT", 8080)
environment ENV.fetch("RACK_ENV", "production")

# OpenShift friendly stdout logging
stdout_redirect nil, nil, false
