defmodule Dashboard.Source.Command do
  @moduledoc """
  Reads the host by running `grm-status --json`.

  The argument vector is fixed: the executable comes from configuration and
  nothing a browser sends can reach it. The command runs under coreutils
  `timeout` so a hung read cannot pile up behind the poller.

  Options: `:command` (required, path to `grm-status`) and `:timeout_seconds`
  (default 10).
  """

  @behaviour Dashboard.Source

  alias Dashboard.Status

  @timeout_exit_status 124

  @impl true
  def demo?, do: false

  @impl true
  def fetch(options) do
    command = Keyword.fetch!(options, :command)
    seconds = Keyword.get(options, :timeout_seconds, 10)

    case run(command, seconds) do
      {output, 0} -> Status.decode(output)
      {_output, @timeout_exit_status} -> {:error, :timeout}
      {output, status} -> {:error, {:exit_status, status, String.slice(output, 0, 500)}}
      :missing -> {:error, {:unreadable, "the status command"}}
    end
  end

  defp run(command, seconds) do
    # -k: a command that ignores TERM is killed five seconds later.
    System.cmd("timeout", ["-k", "5", Integer.to_string(seconds), command, "--json"])
  rescue
    # System.cmd/3 raises when `timeout` itself cannot be started.
    ErlangError -> :missing
  end
end
