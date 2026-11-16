defmodule DashboardWeb.Viewers do
  @moduledoc """
  Who may look at the page when it is served beyond this machine: the
  identities the operator lists in `GRM_DASHBOARD_VIEWERS` (comma-separated),
  read from the header the private-network proxy adds to each request
  (`GRM_DASHBOARD_VIEWER_HEADER`, default `tailscale-user-login`).

  With no list the dashboard behaves as it always has: loopback names only,
  no login. An extra allowed host (`DashboardWeb.AllowedHosts`) without a list
  stops the boot (`check_boot!/0`), so serving the page beyond loopback cannot
  happen without one.

  With a list, a request needs a listed identity unless it is plainly local:
  a loopback `Host` and none of the headers a proxy adds
  (`local?/2`). The router's `DashboardWeb.Plugs.RequireViewer` checks each
  request and records the identity in the signed session; the live socket
  never passes through plugs, so `DashboardWeb.ViewerAuth` checks that record
  again when the page mounts.

  The proxy is trusted to remove any copy of the identity header the client
  sent. Anything that reaches the loopback port directly, such as a process on
  this machine, can send any header: this stops other devices and unlisted
  people on the private network, not local processes.
  """

  @loopback ~w(localhost 127.0.0.1)
  @default_header "tailscale-user-login"
  # Headers a proxy adds; their presence means the request did not come
  # straight from a browser on this machine.
  @proxy_headers ~w(forwarded via x-forwarded-for x-forwarded-host x-forwarded-proto x-real-ip)
  @identity ~r/\A[!-+\--~]{1,254}\z/
  @header_name ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  @max_age 12 * 60 * 60

  @doc "How long, in seconds, a page load counts as proof of identity."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc "The listed identities, lower-cased. Raises on an invalid setting."
  @spec list() :: [String.t()]
  def list, do: parse!(Application.get_env(:dashboard, :viewers))

  @doc "Whether viewers are checked at all."
  @spec required?() :: boolean()
  def required?, do: list() != []

  @doc """
  The identities in a comma-separated setting, lower-cased. Raises
  `ArgumentError` for anything with spaces, control or non-ASCII characters.
  """
  @spec parse!(String.t() | nil) :: [String.t()]
  def parse!(nil), do: []

  def parse!(setting) when is_binary(setting) do
    setting
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&identity!/1)
    |> Enum.uniq()
  end

  @doc "The lower-cased name of the identity header. Raises on an invalid setting."
  @spec header() :: String.t()
  def header do
    name =
      :dashboard
      |> Application.get_env(:viewer_header, @default_header)
      |> String.downcase(:ascii)

    if Regex.match?(@header_name, name) do
      name
    else
      raise ArgumentError,
            "GRM_DASHBOARD_VIEWER_HEADER takes one plain header name, got: #{inspect(name)}"
    end
  end

  @doc "Whether an identity, as a header carries it, is on the list."
  @spec listed?(term()) :: boolean()
  def listed?(identity) when is_binary(identity),
    do: String.downcase(String.trim(identity), :ascii) in list()

  def listed?(_identity), do: false

  @doc """
  Whether a request came straight from a browser on this machine: a loopback
  `Host` and none of the headers a proxy adds, the identity header included.
  """
  @spec local?(String.t() | nil, [{String.t(), String.t()}]) :: boolean()
  def local?(host, headers) when is_binary(host) do
    identity = header()

    String.downcase(host, :ascii) in @loopback and
      not Enum.any?(headers, fn {name, _value} ->
        name in @proxy_headers or name == identity or String.starts_with?(name, "tailscale-")
      end)
  end

  def local?(_host, _headers), do: false

  @doc """
  Stops the boot when the page is served under an extra host name and no
  viewer is listed: that would put it on the private network with no login.
  """
  @spec check_boot!() :: :ok
  def check_boot! do
    header()

    if DashboardWeb.AllowedHosts.extra?() and not required?() do
      raise ArgumentError,
            "an extra allowed host needs GRM_DASHBOARD_VIEWERS (or --viewer): " <>
              "the identities the private-network proxy may let in"
    end

    :ok
  end

  defp identity!(identity) do
    identity = String.downcase(identity, :ascii)

    if Regex.match?(@identity, identity) do
      identity
    else
      raise ArgumentError,
            "GRM_DASHBOARD_VIEWERS takes identities separated by commas, as the proxy's " <>
              "identity header carries them (printable ASCII, no spaces), got: #{inspect(identity)}"
    end
  end
end
