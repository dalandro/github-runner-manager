defmodule DashboardWeb.ErrorHTML do
  @moduledoc "Plain status messages for error responses, such as `Not Found`."

  use DashboardWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
