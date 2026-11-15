defmodule DashboardWeb do
  @moduledoc """
  The web interface: one LiveView and its function components.

      use DashboardWeb, :live_view
      use DashboardWeb, :html

  The quoted blocks run in every module that uses them, so they hold only
  imports and aliases.
  """

  def static_paths, do: ~w(assets favicon.svg robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: DashboardWeb.Endpoint,
        router: DashboardWeb.Router,
        statics: DashboardWeb.static_paths()
    end
  end

  @doc "Dispatches to the block for the given kind of module."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
