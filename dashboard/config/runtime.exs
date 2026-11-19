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

  # Who may look through that proxy, and the header it names them in;
  # validated when the application starts (DashboardWeb.Viewers).
  config :dashboard, viewers: System.get_env("GRM_DASHBOARD_VIEWERS")

  if header = System.get_env("GRM_DASHBOARD_VIEWER_HEADER") do
    config :dashboard, viewer_header: header
  end

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

      # Shows what a runner host pushes to POST /ingest; reads no host itself.
      # Validated at boot (Dashboard.Relay); see docs/dashboard.md.
      "relay" ->
        config :dashboard, :relay,
          push_tokens: System.get_env("GRM_RELAY_PUSH_TOKENS"),
          interval_seconds: String.to_integer(System.get_env("GRM_RELAY_INTERVAL_SECONDS", "5"))

        {Dashboard.Source.Relay, []}

      other ->
        raise "GRM_DASHBOARD_SOURCE must be command, demo or relay, got: #{inspect(other)}"
    end

  case source do
    # A relay read is a lookup in memory: every second, and straight back to
    # that after a stale spell, so a returning host shows at once.
    {Dashboard.Source.Relay, _options} ->
      config :dashboard, Dashboard.Poller, source: source, interval: 1_000, max_backoff: 1_000

    _command_or_demo ->
      config :dashboard, Dashboard.Poller,
        source: source,
        # Never faster than twice a second: each read runs the status command.
        interval: max(String.to_integer(System.get_env("GRM_DASHBOARD_INTERVAL_MS", "2000")), 500)
  end
end
