defmodule TriOnyx.ToolRegistryConsistencyTest do
  @moduledoc """
  Cross-source consistency checks for the tool registry.

  The Python runtime implements the custom tools, so their names
  necessarily exist in two places: `runtime/agent_runner.py` (the
  implementation) and `TriOnyx.ToolRegistry` (the metadata the rest of
  the system keys on). These tests turn silent drift between the two —
  and between the registry and the taint/sensitivity matrices — into
  test failures.
  """
  use ExUnit.Case, async: true

  alias TriOnyx.{SensitivityMatrix, TaintMatrix, ToolRegistry}

  @runtime_source "runtime/agent_runner.py"

  # SDK built-in tools that appear in transcripts (and thus have brief
  # specs) but are not registry tools an agent definition can select.
  @sdk_builtin_briefs ~w(Agent Task TaskCreate TaskUpdate)

  test "every tool implemented in the Python runtime is registered" do
    source = File.read!(@runtime_source)

    runtime_tools =
      ~r/^_[A-Z_]+_TOOL\s*=\s*"([A-Za-z]+)"/m
      |> Regex.scan(source)
      |> Enum.map(fn [_, name] -> name end)

    assert runtime_tools != [],
           "no _TOOL constants found in #{@runtime_source} — did the naming convention change?"

    unregistered = Enum.reject(runtime_tools, &ToolRegistry.known?/1)

    assert unregistered == [],
           "tools implemented in #{@runtime_source} but missing from ToolRegistry: #{inspect(unregistered)}"
  end

  test "taint and sensitivity matrices cover every registered tool" do
    taint_keys = Map.keys(TaintMatrix.all_tool_taints())
    sensitivity_keys = Map.keys(SensitivityMatrix.all_tool_sensitivities())

    assert ToolRegistry.known_tools() -- taint_keys == [],
           "registered tools missing from TaintMatrix"

    assert ToolRegistry.known_tools() -- sensitivity_keys == [],
           "registered tools missing from SensitivityMatrix"

    orphaned =
      (taint_keys ++ sensitivity_keys)
      |> Enum.uniq()
      |> Enum.reject(&ToolRegistry.known?/1)

    assert orphaned == [],
           "matrix entries for tools not in ToolRegistry: #{inspect(orphaned)}"
  end

  test "brief specs reference only registered tools or SDK built-ins" do
    unknown =
      ToolRegistry.brief_specs()
      |> Map.keys()
      |> Enum.reject(fn tool ->
        ToolRegistry.known?(tool) or tool in @sdk_builtin_briefs
      end)

    assert unknown == [],
           "brief specs for unknown tools: #{inspect(unknown)}"
  end

  test "display entries cover every registered tool" do
    displayed =
      ToolRegistry.display_entries()
      |> Enum.map(& &1.display)
      |> Enum.uniq()

    assert ToolRegistry.known_tools() -- displayed == [],
           "registered tools missing from display_entries"
  end
end
