defmodule DashboardWeb.ViewerAuth do
  @moduledoc """
  The live socket's half of the viewer check. Phoenix dispatches sockets
  before endpoint and router plugs, so `DashboardWeb.Plugs.RequireViewer`
  never sees them. With a viewer list, a page mounts only when its signed
  session names a listed viewer recorded within `DashboardWeb.Viewers.max_age/0`.
  With a relay viewer password, only when it records a sign-in with the
  current password (`DashboardWeb.RelayLogin.session_valid?/4`, checked by
  `DashboardWeb.Plugs.RelayLogin` on page requests); an open page is sent
  back to `/` when that sign-in runs out.
  Otherwise the page is sent back to `/`, where the plugs answer.
  """

  import Phoenix.LiveView

  alias Dashboard.Relay
  alias DashboardWeb.{Endpoint, RelayLogin, Viewers}

  def on_mount(:require_viewer, _params, session, socket) do
    cond do
      not allowed?(session) -> {:halt, redirect(socket, to: "/")}
      Relay.login_required?() -> {:cont, end_with_sign_in(socket, session)}
      true -> {:cont, socket}
    end
  end

  # A page stays connected for as long as the board is open; the sign-in that
  # let it mount does not.
  defp end_with_sign_in(socket, %{"viewer_at" => at}) do
    if connected?(socket) do
      seconds_left = at + RelayLogin.max_age() - System.system_time(:second)
      Process.send_after(self(), :relay_sign_in_over, max(seconds_left, 0) * 1_000)
    end

    attach_hook(socket, :relay_sign_in, :handle_info, fn
      :relay_sign_in_over, socket -> {:halt, redirect(socket, to: "/")}
      _message, socket -> {:cont, socket}
    end)
  end

  @doc """
  Whether the live socket may connect: with a relay viewer password, only
  with a sign-in in the signed session (`nil` when the CSRF check failed).
  """
  @spec socket_allowed?(map() | nil) :: boolean()
  def socket_allowed?(session),
    do: not Relay.login_required?() or relay_signed_in?(session || %{})

  defp allowed?(session) do
    cond do
      Relay.login_required?() ->
        relay_signed_in?(session)

      Viewers.required?() ->
        recent_viewer?(session)

      true ->
        true
    end
  end

  defp recent_viewer?(%{"viewer" => viewer, "viewer_at" => at}) when is_integer(at) do
    Viewers.listed?(viewer) and (System.system_time(:second) - at) in 0..Viewers.max_age()
  end

  defp recent_viewer?(_session), do: false

  defp relay_signed_in?(session) do
    RelayLogin.session_valid?(
      session,
      Relay.viewer_password(),
      Endpoint.config(:secret_key_base),
      System.system_time(:second)
    )
  end
end
