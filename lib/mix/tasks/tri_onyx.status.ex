defmodule Mix.Tasks.TriOnyx.Status do
  @shortdoc "Displays the status of all TriOnyx agents"

  @moduledoc """
  CLI dashboard showing all registered agents with their status,
  taint information, and risk scores.

      $ mix tri_onyx.status

  Displays:

  - Agent name and session ID (if active)
  - Running status and uptime
  - Taint status and sources
  - Input risk, tool danger, and effective risk
  - Allowed tools and network policy
  """

  use Mix.Task

  alias TriOnyx.AgentLoader
  alias TriOnyx.RiskScorer

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case AgentLoader.load_all() do
      {:ok, definitions} when definitions != [] ->
        print_header(length(definitions))

        Enum.each(definitions, fn definition ->
          print_agent(definition)
        end)

      {:ok, []} ->
        Mix.shell().info("TriOnyx Gateway — no agents found")
        Mix.shell().info("")
        agents_dir = Application.get_env(:tri_onyx, :agents_dir, "./workspace/agent-definitions")
        Mix.shell().info("  Agents directory: #{Path.expand(agents_dir)}")
        Mix.shell().info("  Add .md agent definition files to get started.")

      {:error, :directory_not_found} ->
        agents_dir = Application.get_env(:tri_onyx, :agents_dir, "./workspace/agent-definitions")
        Mix.shell().error("Agents directory not found: #{Path.expand(agents_dir)}")
        Mix.shell().info("Set TRI_ONYX_AGENTS_DIR or create the directory.")
    end
  end

  @spec print_header(non_neg_integer()) :: :ok
  defp print_header(count) do
    Mix.shell().info("TriOnyx Gateway — #{count} agent(s) defined")
    Mix.shell().info("")
  end

  @spec print_agent(TriOnyx.AgentDefinition.t()) :: :ok
  defp print_agent(definition) do
    taint = RiskScorer.infer_taint(:external_message, definition.tools)
    sensitivity = RiskScorer.infer_sensitivity(definition.tools)
    effective_risk = RiskScorer.effective_risk(taint, sensitivity)

    Mix.shell().info("  Agent: #{definition.name}")

    if definition.description do
      Mix.shell().info("    Description:    #{definition.description}")
    end

    Mix.shell().info("    Model:          #{definition.model}")
    Mix.shell().info("    Taint:          #{taint}")
    Mix.shell().info("    Sensitivity:        #{sensitivity}")
    Mix.shell().info("    Effective risk: #{RiskScorer.format_risk(effective_risk)}")
    Mix.shell().info("    Network:        #{format_network(definition.network)}")

    if definition.fs_read != [] do
      Mix.shell().info("    FS read:        #{Enum.join(definition.fs_read, ", ")}")
    end

    if definition.fs_write != [] do
      Mix.shell().info("    FS write:       #{Enum.join(definition.fs_write, ", ")}")
    end

    Mix.shell().info("")
  end

  @spec format_network(TriOnyx.AgentDefinition.network_policy()) :: String.t()
  defp format_network(:none), do: "none"
  defp format_network(:outbound), do: "outbound"
  defp format_network(hosts) when is_list(hosts), do: Enum.join(hosts, ", ")
end
