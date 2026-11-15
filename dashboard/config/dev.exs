import Config

config :dashboard, DashboardWeb.Endpoint, debug_errors: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view, enable_expensive_runtime_checks: true
