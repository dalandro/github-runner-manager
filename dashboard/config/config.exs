import Config

# Loopback only, by design: the page is read-only, and needs a login
# (DashboardWeb.Viewers) only when a proxy serves it under another name. See
# docs/dashboard.md before changing the address. The Host and origin checks
# share one list of names (DashboardWeb.AllowedHosts). A phone and a laptop
# need a handful of connections, not Bandit's default sixteen thousand.
config :dashboard, DashboardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, thousand_island_options: [num_acceptors: 4, num_connections: 32]],
  check_origin: {DashboardWeb.AllowedHosts, :origin_allowed?, []},
  render_errors: [formats: [html: DashboardWeb.ErrorHTML], layout: false],
  pubsub_server: Dashboard.PubSub,
  # Salts namespace signed data; the secret is secret_key_base (config/runtime.exs).
  live_view: [signing_salt: "grm-dashboard-live-view"]

config :dashboard, Dashboard.Poller,
  source: {Dashboard.Source.Demo, []},
  interval: 2_000,
  max_backoff: 30_000

config :logger, :default_formatter, format: "$time [$level] $message\n"

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
