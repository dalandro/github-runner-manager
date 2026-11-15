import Config

config :dashboard, DashboardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4292],
  secret_key_base: String.duplicate("test-only-", 7),
  server: false

# Tests start their own pollers with stub sources.
config :dashboard, start_poller: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view, enable_expensive_runtime_checks: true
