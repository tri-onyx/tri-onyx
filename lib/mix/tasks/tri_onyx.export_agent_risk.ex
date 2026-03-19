defmodule Mix.Tasks.TriOnyx.ExportAgentRisk do
  @shortdoc "Exports per-agent risk profiles as JSON"

  @moduledoc """
  Computes worst-case risk profiles for all agent definitions and outputs
  them as JSON to stdout.

      $ mix tri_onyx.export_agent_risk

  For each agent, computes:

  - **taint** — worst-case across all declared input sources and tool taints
  - **sensitivity** — worst-case across tools and privileged mounts
  - **capability** — highest tool capability, with Bash promoted if network access
  - **effective_risk** — 3D trifecta result (taint × sensitivity × capability)

  Each axis includes its driver list (which tools/sources/mounts contributed).

  Output is a JSON object keyed by agent name. This is consumed by
  `scripts/generate-agent-docs.py` to render risk profiles in the docs.
  """

  use Mix.Task

  require Logger

  alias TriOnyx.AgentLoader
  alias TriOnyx.RiskScorer
  alias TriOnyx.TaintMatrix
  alias TriOnyx.SensitivityMatrix
  alias TriOnyx.ToolRegistry

  @impl Mix.Task
  def run(args) do
    # Suppress logger output to keep stdout clean for JSON
    Logger.configure(level: :none)
    Mix.Task.run("app.start")

    output_path =
      case args do
        ["-o", path | _] -> path
        _ -> nil
      end

    case AgentLoader.load_all() do
      {:ok, definitions} ->
        result =
          definitions
          |> Enum.map(fn def -> {def.name, build_risk_profile(def)} end)
          |> Enum.into(%{})

        json = Jason.encode!(result, pretty: true)

        if output_path do
          File.write!(output_path, json <> "\n")
          Mix.shell().info("Wrote #{output_path}")
        else
          IO.puts(json)
        end

      {:error, :directory_not_found} ->
        Mix.shell().error("Agents directory not found")
        exit({:shutdown, 1})
    end
  end

  @spec build_risk_profile(TriOnyx.AgentDefinition.t()) :: map()
  defp build_risk_profile(definition) do
    {taint, taint_drivers} = compute_taint(definition)
    {sensitivity, sensitivity_drivers} = compute_sensitivity(definition)
    {capability, capability_drivers} = compute_capability(definition)
    effective_risk = RiskScorer.effective_risk(taint, sensitivity, capability)

    %{
      taint: Atom.to_string(taint),
      taint_drivers: taint_drivers,
      sensitivity: Atom.to_string(sensitivity),
      sensitivity_drivers: sensitivity_drivers,
      capability: Atom.to_string(capability),
      capability_drivers: capability_drivers,
      effective_risk: Atom.to_string(effective_risk),
      input_sources: Enum.map(definition.input_sources, &Atom.to_string/1)
    }
  end

  # Worst-case taint: max of base_taint, all input source taints, and all tool taints.
  @spec compute_taint(TriOnyx.AgentDefinition.t()) :: {atom(), [String.t()]}
  defp compute_taint(definition) do
    drivers = []

    # Base taint
    {level, drivers} =
      if definition.base_taint != :low do
        {:low, ["base_taint: #{definition.base_taint}" | drivers]}
      else
        {:low, drivers}
      end

    level = higher(level, definition.base_taint)

    # Input source taints (worst-case across all declared sources)
    {level, drivers} =
      Enum.reduce(definition.input_sources, {level, drivers}, fn source, {lvl, drv} ->
        source_taint = TaintMatrix.trigger_taint(source)

        if rank(source_taint) > rank(lvl) do
          {source_taint, [Atom.to_string(source) | drv]}
        else
          if source_taint != :low, do: {lvl, [Atom.to_string(source) | drv]}, else: {lvl, drv}
        end
      end)

    # Tool taints (context-aware: Bash with network = high)
    has_network = definition.network != :none

    {level, drivers} =
      Enum.reduce(definition.tools, {level, drivers}, fn tool, {lvl, drv} ->
        tool_taint =
          case tool do
            "Bash" -> if has_network, do: TaintMatrix.tool_taint("Bash", :network), else: TaintMatrix.tool_taint("Bash", :isolated)
            other -> TaintMatrix.tool_taint(other)
          end

        if tool_taint != :low do
          new_lvl = higher(lvl, tool_taint)
          {new_lvl, [tool | drv]}
        else
          {lvl, drv}
        end
      end)

    {level, Enum.reverse(Enum.uniq(drivers))}
  end

  # Worst-case sensitivity: max of tool sensitivities + mount sensitivities.
  @spec compute_sensitivity(TriOnyx.AgentDefinition.t()) :: {atom(), [String.t()]}
  defp compute_sensitivity(definition) do
    # Tool sensitivities
    {level, drivers} =
      Enum.reduce(definition.tools, {:low, []}, fn tool, {lvl, drv} ->
        tool_sens = SensitivityMatrix.tool_sensitivity(tool)

        if tool_sens != :low do
          {higher(lvl, tool_sens), [tool | drv]}
        else
          {lvl, drv}
        end
      end)

    # Mount sensitivities
    mounts = [
      {:docker_socket, definition.docker_socket, "docker_socket"},
      {:trionyx_repo, definition.trionyx_repo, "trionyx_repo"}
    ]

    {level, drivers} =
      Enum.reduce(mounts, {level, drivers}, fn {mount, enabled, label}, {lvl, drv} ->
        if enabled do
          mount_sens = SensitivityMatrix.mount_sensitivity(mount)

          if mount_sens != :low do
            {higher(lvl, mount_sens), [label | drv]}
          else
            {lvl, drv}
          end
        else
          {lvl, drv}
        end
      end)

    # Input source sensitivities
    {level, drivers} =
      Enum.reduce(definition.input_sources, {level, drivers}, fn source, {lvl, drv} ->
        source_sens = SensitivityMatrix.trigger_sensitivity(source)

        if source_sens != :low do
          {higher(lvl, source_sens), [Atom.to_string(source) | drv]}
        else
          {lvl, drv}
        end
      end)

    {level, Enum.reverse(Enum.uniq(drivers))}
  end

  # Capability: max tool capability, Bash promoted to high with network.
  @spec compute_capability(TriOnyx.AgentDefinition.t()) :: {atom(), [String.t()]}
  defp compute_capability(definition) do
    has_network = definition.network != :none

    {level, drivers} =
      Enum.reduce(definition.tools, {:low, []}, fn tool, {lvl, drv} ->
        base_cap = ToolRegistry.capability_level(tool)

        effective_cap =
          if tool == "Bash" and has_network and base_cap == :medium do
            :high
          else
            base_cap
          end

        if effective_cap != :low do
          {higher(lvl, effective_cap), [tool | drv]}
        else
          {lvl, drv}
        end
      end)

    {level, Enum.reverse(Enum.uniq(drivers))}
  end

  @rank %{low: 0, medium: 1, high: 2}

  defp rank(level), do: Map.fetch!(@rank, level)

  defp higher(a, b) do
    if rank(a) >= rank(b), do: a, else: b
  end
end
