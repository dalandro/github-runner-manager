defmodule DashboardWeb.ConnCase do
  @moduledoc "Test case for requests and LiveViews against the endpoint."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint DashboardWeb.Endpoint

      use DashboardWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn(:get, "http://localhost/")}
  end
end
