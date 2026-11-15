import Config

# Everything the operator can set arrives through the environment, normally
# from bin/grm-dashboard. Unknown values fail at boot instead of being guessed.
if config_env() != :test do
  if System.get_env("PHX_SERVER") do
    config :dashboard, DashboardWeb.Endpoint, server: true
  end

  # No sessions outlive a restart and nothing is stored in them, so a fresh
  # secret per boot is enough and keeps secrets out of the repository.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  config :dashboard, DashboardWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4290"))],
    secret_key_base: secret_key_base

  # Extra host names a proxy on this machine serves the page under; validated
  # when the application starts. The listening address does not change.
  config :dashboard, allowed_hosts: System.get_env("GRM_DASHBOARD_ALLOWED_HOSTS")

  source =
    case System.get_env("GRM_DASHBOARD_SOURCE", "command") do
      "command" ->
        command =
          System.get_env("GRM_STATUS_COMMAND") ||
            Path.expand("../../bin/grm-status", __DIR__)

        {Dashboard.Source.Command, command: command}

      "demo" ->
        case System.get_env("GRM_DASHBOARD_DEMO_FILE") do
          nil -> {Dashboard.Source.Demo, []}
          path -> {Dashboard.Source.Demo, path: path}
        end

      other ->
        raise "GRM_DASHBOARD_SOURCE must be command or demo, got: #{inspect(other)}"
    end

  config :dashboard, Dashboard.Poller,
    source: source,
    # Never faster than twice a second: each read runs the status command.
    interval: max(String.to_integer(System.get_env("GRM_DASHBOARD_INTERVAL_MS", "2000")), 500)
end
