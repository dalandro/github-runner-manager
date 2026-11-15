defmodule DashboardWeb.Layouts do
  @moduledoc "The HTML document around the LiveView."

  use DashboardWeb, :html

  embed_templates "layouts/*"
end
