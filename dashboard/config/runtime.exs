import Config

# Everything the operator can set arrives through the environment, normally
# from bin/grm-dashboard. Unknown values fail at boot instead of being guessed.
if config_env() != :test do
  if System.get_env("PHX_SERVER") do
    config :dashboard, DashboardWeb.Endpoint, server: true
  end

  # On this host no session needs to outlive a restart, so a fresh secret per
  # boot is enough and keeps secrets out of the repository. A public relay
  # needs a lasting one (below).
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

  # A dashboard that reads this host never listens beyond loopback.
  if System.get_env("GRM_RELAY_PUBLIC_HOST") && System.get_env("GRM_DASHBOARD_SOURCE") != "relay" do
    raise "GRM_RELAY_PUBLIC_HOST is for relay mode only (GRM_DASHBOARD_SOURCE=relay)"
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
        public_host = System.get_env("GRM_RELAY_PUBLIC_HOST")

        config :dashboard, :relay,
          push_tokens: System.get_env("GRM_RELAY_PUSH_TOKENS"),
          interval_seconds: String.to_integer(System.get_env("GRM_RELAY_INTERVAL_SECONDS", "5")),
          public_host: public_host,
          viewer_password: System.get_env("GRM_RELAY_VIEWER_PASSWORD")

        # The one place the dashboard listens beyond loopback: a relay with a
        # public name, behind Fly's proxy, which reaches the machine on its
        # private address. Without a viewer password it does not boot.
        if public_host do
          # Sign-ins live in the signed session, so they must outlive a deploy.
          if byte_size(String.trim(System.get_env("SECRET_KEY_BASE", ""))) < 64 do
            raise "GRM_RELAY_PUBLIC_HOST needs SECRET_KEY_BASE (64 characters or more, " <>
                    "e.g. from: openssl rand -base64 48), so sign-ins outlive a restart"
          end

          config :dashboard, DashboardWeb.Endpoint,
            http: [ip: {0, 0, 0, 0}],
            url: [
              host: Dashboard.Relay.parse_public_host!(public_host),
              scheme: "https",
              port: 443
            ]
        end

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
