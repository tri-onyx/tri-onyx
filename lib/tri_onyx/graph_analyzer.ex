defmodule TriOnyx.GraphAnalyzer do
  @moduledoc """
  Computes transitive risk propagation across agent topologies.

  Builds a directed graph from agent filesystem overlaps (write->read edges)
  and traces how information risk flows through agent chains. Used to compute
  max_input_risk per agent and detect security policy violations.

  Biba (integrity) checks use the **taint** axis.
  Bell-LaPadula (confidentiality) checks use the **sensitivity** axis.

  All functions are pure — no GenServer, no side effects.
  """

  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskScorer
  alias TriOnyx.TaintMatrix
  alias TriOnyx.SensitivityMatrix
  alias TriOnyx.ToolRegistry

  @type agent_analysis :: %{
          max_input_taint: InformationClassifier.information_level(),
          max_input_sensitivity: InformationClassifier.sensitivity_level(),
          max_input_risk: InformationClassifier.information_level(),
          capability_level: :low | :medium | :high,
          incoming_edges: [%{from: String.t(), paths: [String.t()]}],
          risk_chain: [String.t()]
        }

  @doc """
  Analyzes risk propagation across a set of agent definitions.

  Takes a list of agent definitions and a risk manifest (map of path -> risk entry).
  Builds write->read edges by finding filesystem path overlaps, adds messaging
  edges from declared send_to/receive_from pairs, then traces transitive risk
  propagation.

  Returns `%{agent_name => agent_analysis}`.
  """
  @spec analyze([map()], map()) :: %{String.t() => agent_analysis()}
  def analyze(definitions, risk_manifest), do: analyze(definitions, risk_manifest, %{})

  @doc """
  Analyzes risk propagation with optional base levels for transitive propagation.

  When `base_levels` is provided (agent_name => %{taint, sensitivity}), transitive
  propagation is computed via fixed-point iteration. Otherwise, only direct edge
  manifest data is used for max_input_taint/sensitivity.
  """
  @spec analyze([map()], map(), map()) :: %{String.t() => agent_analysis()}
  def analyze(definitions, risk_manifest, base_levels) do
    fs_edges = build_filesystem_edges(definitions, risk_manifest)
    msg_edges = build_messaging_edges(definitions)
    bcp_edges = build_bcp_edges(definitions)
    edges = merge_edges(fs_edges, msg_edges) |> merge_edges(bcp_edges)

    # Compute transitive propagation if base levels provided
    propagated =
      if base_levels != %{} do
        propagate_levels(definitions, edges, base_levels)
      else
        %{}
      end

    definitions
    |> Enum.map(fn definition ->
      incoming = Map.get(edges, definition.name, [])

      # Compute max taint and sensitivity from incoming edges using manifest data
      {max_taint, max_sensitivity} =
        incoming
        |> Enum.reduce({:low, :low}, fn edge, {t_acc, s_acc} ->
          edge_taint = lookup_edge_taint(edge, risk_manifest)
          edge_sensitivity = lookup_edge_sensitivity(edge, risk_manifest)
          {InformationClassifier.higher_level(t_acc, edge_taint),
           InformationClassifier.higher_level(s_acc, edge_sensitivity)}
        end)

      max_risk = InformationClassifier.higher_level(max_taint, max_sensitivity)
      chain = trace_risk_chain(definition.name, edges, MapSet.new())
      capability = RiskScorer.infer_capability(definition.tools, definition.network)

      prop = Map.get(propagated, definition.name, %{})

      {definition.name,
       %{
         max_input_taint: max_taint,
         max_input_sensitivity: max_sensitivity,
         max_input_risk: max_risk,
         capability_level: capability,
         incoming_edges: incoming,
         risk_chain: chain,
         propagated_taint: Map.get(prop, :taint),
         propagated_sensitivity: Map.get(prop, :sensitivity),
         taint_sources: Map.get(prop, :taint_sources, []),
         sensitivity_sources: Map.get(prop, :sensitivity_sources, [])
       }}
    end)
    |> Map.new()
  end

  @doc """
  Detects Biba integrity violations using the **taint** axis.

  A Biba violation is when a high-taint writer produces data consumed by a
  low-taint reader. Untrusted data enters a trusted context.
  """
  @spec biba_violations(map(), [map()], map()) :: [map()]
  def biba_violations(analysis, _definitions, taint_levels) do
    analysis
    |> Enum.flat_map(fn {reader_name, %{incoming_edges: edges}} ->
      reader_taint = extract_taint(taint_levels, reader_name)

      Enum.flat_map(edges, fn %{from: writer_name} ->
        writer_taint = extract_taint(taint_levels, writer_name)

        if level_rank(writer_taint) > level_rank(reader_taint) do
          [
            %{
              "reader" => reader_name,
              "writer" => writer_name,
              "description" =>
                "Integrity violation: #{writer_name} (taint: #{writer_taint}) writes data " <>
                  "read by #{reader_name} (taint: #{reader_taint}). Untrusted data enters trusted context."
            }
          ]
        else
          []
        end
      end)
    end)
  end

  @doc """
  Detects Bell-LaPadula confidentiality violations using the **sensitivity** axis.

  A BLP violation is when a high-sensitivity writer writes to paths readable by a
  lower-sensitivity, network-capable agent. Sensitive data could be exfiltrated.
  """
  @spec bell_lapadula_violations([map()], map(), map()) :: [map()]
  def bell_lapadula_violations(definitions, risk_manifest, sensitivity_levels) do
    fs_violations = bell_lapadula_fs_violations(definitions, risk_manifest, sensitivity_levels)
    msg_violations = bell_lapadula_messaging_violations(definitions, sensitivity_levels)
    fs_violations ++ msg_violations
  end

  @doc """
  DFS through edges to find the chain of agents contributing risk to a target.

  Prevents cycles with a visited set. Returns list of agent names in the chain.
  """
  @spec trace_risk_chain(String.t(), map(), MapSet.t()) :: [String.t()]
  def trace_risk_chain(agent_name, edges, visited) do
    if MapSet.member?(visited, agent_name) do
      []
    else
      visited = MapSet.put(visited, agent_name)
      incoming = Map.get(edges, agent_name, [])

      Enum.flat_map(incoming, fn %{from: source} ->
        upstream = trace_risk_chain(source, edges, visited)
        upstream ++ [source]
      end)
    end
  end

  @doc """
  Infers worst-case taint level for an agent based on its data sources.

  Only factors that introduce external/untrusted data affect taint:
  network access and tools that fetch external content.
  """
  @spec worst_case_taint(map()) :: InformationClassifier.information_level()
  def worst_case_taint(definition), do: worst_case_taint(definition, %{})

  @doc """
  Infers worst-case taint with peer resolution.

  When `all_definitions` is provided (name → definition map), BCP channels
  are resolved: a controller receiving BCP responses from a peer inherits
  `step_down(peer_taint)`. Without peer context, BCP channels are ignored.

  Taint sources (input quality only, never tools):
  - Network access or WebFetch/WebSearch → `:high`
  - Free-text messaging peers (receive_from) → `:medium`
  - BCP controller channel → `step_down(peer's worst-case taint)`
  - No external inputs → `:low`
  """
  @spec worst_case_taint(map(), map()) :: InformationClassifier.information_level()
  def worst_case_taint(definition, all_definitions) do
    has_external_input =
      Enum.any?(definition.tools, fn tool ->
        tool in ["WebFetch", "WebSearch"]
      end)

    has_messaging_peers = definition.receive_from != []

    # BCP taint: for each controller channel, resolve peer's worst-case
    # taint and step it down by one level.
    bcp_taint =
      definition.bcp_channels
      |> Enum.filter(fn ch -> ch.role == :controller end)
      |> Enum.map(fn ch ->
        case Map.get(all_definitions, ch.peer) do
          nil -> :low
          peer_def ->
            # Compute peer taint without all_definitions to avoid cycles
            peer_taint = worst_case_taint(peer_def)
            InformationClassifier.step_down(peer_taint)
        end
      end)
      |> Enum.reduce(:low, &InformationClassifier.higher_level/2)

    base =
      cond do
        has_network?(definition.network) -> :high
        has_external_input -> :high
        has_messaging_peers -> :medium
        true -> :low
      end

    # Factor in input_sources
    input_source_taint =
      Map.get(definition, :input_sources, [])
      |> Enum.map(&TaintMatrix.trigger_taint/1)
      |> Enum.reduce(:low, &InformationClassifier.higher_level/2)

    result = InformationClassifier.higher_level(base, bcp_taint)
    result = InformationClassifier.higher_level(result, input_source_taint)

    # Factor in base_taint from agent definition as a floor
    base_taint_floor = Map.get(definition, :base_taint, :low)
    InformationClassifier.higher_level(result, base_taint_floor)
  end

  @doc """
  Infers worst-case sensitivity level for an agent based on its tool metadata.

  Currently returns `:low` for all built-in tools since the gateway doesn't
  attach credentials yet.
  """
  @spec worst_case_sensitivity(map()) :: InformationClassifier.sensitivity_level()
  def worst_case_sensitivity(definition) do
    tool_sensitivity =
      definition.tools
      |> Enum.map(fn tool_name ->
        meta = TriOnyx.ToolRegistry.tool_meta(tool_name)
        InformationClassifier.classify_tool_sensitivity(tool_name, meta)
      end)
      |> Enum.reduce(:low, &InformationClassifier.higher_level/2)

    input_source_sensitivity =
      Map.get(definition, :input_sources, [])
      |> Enum.map(&SensitivityMatrix.trigger_sensitivity/1)
      |> Enum.reduce(:low, &InformationClassifier.higher_level/2)

    InformationClassifier.higher_level(tool_sensitivity, input_source_sensitivity)
  end

  @doc """
  Infers worst-case information level. Returns `max(taint, sensitivity)`.

  Kept for backward compat.
  """
  @spec worst_case_level(map()) :: InformationClassifier.information_level()
  def worst_case_level(definition) do
    InformationClassifier.higher_level(
      worst_case_taint(definition),
      worst_case_sensitivity(definition)
    )
  end

  @doc """
  Computes fully propagated taint and sensitivity for all agents via fixed-point iteration.

  Takes agent definitions, pre-built edges map, and base levels (from worst_case_* functions).
  Returns a map of agent_name => %{taint, sensitivity, taint_sources, sensitivity_sources}.

  BCP edges apply `step_down/1` on taint but pass sensitivity through unchanged.
  Both axes are monotonic (only escalate), guaranteeing convergence.
  """
  @spec propagate_levels([map()], map(), map()) :: map()
  def propagate_levels(definitions, edges, base_levels) do
    agent_names = Enum.map(definitions, & &1.name)

    initial =
      Map.new(agent_names, fn name ->
        base = Map.get(base_levels, name, %{taint: :low, sensitivity: :low})
        {name, %{taint: base.taint, sensitivity: base.sensitivity}}
      end)

    resolved = do_propagate_levels(agent_names, edges, base_levels, initial)

    # Build source tracking
    Map.new(agent_names, fn name ->
      incoming = Map.get(edges, name, [])
      resolved_t = resolved[name].taint
      resolved_s = resolved[name].sensitivity

      taint_sources =
        incoming
        |> Enum.map(fn edge ->
          src_taint = resolved[edge.from].taint
          contributed = if edge.edge_type == :bcp, do: InformationClassifier.step_down(src_taint), else: src_taint
          %{from: edge.from, contributed: contributed, edge_type: edge.edge_type}
        end)
        |> Enum.filter(fn %{contributed: c} -> c == resolved_t and resolved_t != :low end)

      sensitivity_sources =
        incoming
        |> Enum.map(fn edge ->
          src_sens = resolved[edge.from].sensitivity
          %{from: edge.from, contributed: src_sens, edge_type: edge.edge_type}
        end)
        |> Enum.filter(fn %{contributed: c} -> c == resolved_s and resolved_s != :low end)

      {name, %{
        taint: resolved_t,
        sensitivity: resolved_s,
        taint_sources: taint_sources,
        sensitivity_sources: sensitivity_sources
      }}
    end)
  end

  defp do_propagate_levels(agent_names, edges, base_levels, current) do
    next =
      Map.new(agent_names, fn name ->
        base = Map.get(base_levels, name, %{taint: :low, sensitivity: :low})
        incoming = Map.get(edges, name, [])

        {new_t, new_s} =
          Enum.reduce(incoming, {base.taint, base.sensitivity}, fn edge, {t_acc, s_acc} ->
            src = current[edge.from]
            src_taint = if edge.edge_type == :bcp, do: InformationClassifier.step_down(src.taint), else: src.taint
            src_sens = src.sensitivity
            {InformationClassifier.higher_level(t_acc, src_taint),
             InformationClassifier.higher_level(s_acc, src_sens)}
          end)

        {name, %{taint: new_t, sensitivity: new_s}}
      end)

    if next == current, do: current, else: do_propagate_levels(agent_names, edges, base_levels, next)
  end

  # --- Private Functions ---

  # Extract taint from a levels map that may contain either the new two-axis
  # format or the legacy single-axis format.
  @spec extract_taint(map(), String.t()) :: InformationClassifier.information_level()
  defp extract_taint(levels, agent_name) do
    case Map.get(levels, agent_name) do
      %{taint: taint} -> taint
      level when level in [:low, :medium, :high] -> level
      _ -> :low
    end
  end

  @spec extract_sensitivity(map(), String.t()) :: InformationClassifier.sensitivity_level()
  defp extract_sensitivity(levels, agent_name) do
    case Map.get(levels, agent_name) do
      %{sensitivity: sensitivity} -> sensitivity
      # Legacy single-axis: treat as sensitivity for BLP checks
      level when level in [:low, :medium, :high] -> level
      _ -> :low
    end
  end

  # Look up taint level from an edge's paths in the manifest
  @spec lookup_edge_taint(map(), map()) :: InformationClassifier.information_level()
  defp lookup_edge_taint(%{paths: paths}, risk_manifest) do
    paths
    |> Enum.map(fn path -> lookup_manifest_taint(path, risk_manifest) end)
    |> Enum.reduce(:low, &InformationClassifier.higher_level/2)
  end

  @spec lookup_edge_sensitivity(map(), map()) :: InformationClassifier.sensitivity_level()
  defp lookup_edge_sensitivity(%{paths: paths}, risk_manifest) do
    paths
    |> Enum.map(fn path -> lookup_manifest_sensitivity(path, risk_manifest) end)
    |> Enum.reduce(:low, &InformationClassifier.higher_level/2)
  end

  @spec build_filesystem_edges([map()], map()) :: %{String.t() => [map()]}
  defp build_filesystem_edges(definitions, _risk_manifest) do
    for writer <- definitions,
        reader <- definitions,
        writer.name != reader.name,
        writer.fs_write != [],
        reader.fs_read != [],
        reduce: %{} do
      acc ->
        overlapping = find_overlapping_paths(writer.fs_write, reader.fs_read)

        if overlapping != [] do
          edge = %{
            from: writer.name,
            paths: overlapping,
            edge_type: :filesystem
          }

          Map.update(acc, reader.name, [edge], &[edge | &1])
        else
          acc
        end
    end
  end

  @spec build_messaging_edges([map()]) :: %{String.t() => [map()]}
  defp build_messaging_edges(definitions) do
    def_map = Map.new(definitions, &{&1.name, &1})

    for sender <- definitions,
        target_name <- Map.get(sender, :send_to, []),
        receiver = Map.get(def_map, target_name),
        receiver != nil,
        sender.name in Map.get(receiver, :receive_from, []),
        reduce: %{} do
      acc ->
        edge = %{
          from: sender.name,
          paths: [],
          edge_type: :messaging
        }

        Map.update(acc, target_name, [edge], &[edge | &1])
    end
  end

  # Builds directed edges from BCP channel declarations.
  #
  # A BCP channel between a controller and a reader creates an edge from
  # the reader to the controller (information flows from reader to controller
  # in the BCP model — the reader extracts data, the controller consumes it).
  @spec build_bcp_edges([map()]) :: %{String.t() => [map()]}
  defp build_bcp_edges(definitions) do
    def_map = Map.new(definitions, &{&1.name, &1})

    for definition <- definitions,
        channel <- Map.get(definition, :bcp_channels, []),
        channel.role == :controller,
        Map.has_key?(def_map, channel.peer),
        reduce: %{} do
      acc ->
        edge = %{
          from: channel.peer,
          paths: [],
          edge_type: :bcp,
          max_category: channel.max_category,
          budget_bits: channel.budget_bits
        }

        Map.update(acc, definition.name, [edge], &[edge | &1])
    end
  end

  @doc """
  Computes per-tool driver breakdowns for tooltip display.

  Returns a map with taint_drivers, sensitivity_drivers, and capability_drivers,
  each listing tools with level > :low. Bash is promoted to :high for taint
  and capability when the agent has network access.

  Deprecated: use `rating_drivers/2` for unified source tracking.
  """
  @spec tool_drivers(map()) :: %{
          taint_drivers: [%{tool: String.t(), level: atom()}],
          sensitivity_drivers: [%{tool: String.t(), level: atom()}],
          capability_drivers: [%{tool: String.t(), level: atom()}]
        }
  def tool_drivers(definition) do
    has_net = has_network?(definition.network)

    taint_drivers =
      definition.tools
      |> Enum.map(fn tool ->
        level = TaintMatrix.tool_taint(tool)
        level = if tool == "Bash" and has_net, do: :high, else: level
        %{tool: tool, level: level}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    sensitivity_drivers =
      definition.tools
      |> Enum.map(fn tool ->
        %{tool: tool, level: SensitivityMatrix.tool_sensitivity(tool)}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    capability_drivers =
      definition.tools
      |> Enum.map(fn tool ->
        level = ToolRegistry.capability_level(tool)
        level = if tool == "Bash" and has_net and level == :medium, do: :high, else: level
        %{tool: tool, level: level}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    %{
      taint_drivers: taint_drivers,
      sensitivity_drivers: sensitivity_drivers,
      capability_drivers: capability_drivers
    }
  end

  @doc """
  Computes unified rating drivers for an agent, including tools, input sources,
  messaging peers, network, BCP channels, and base_taint.

  Returns a map with:
  - `taint_sources` — all taint contributors (tools + inputs + peers + network + BCP + base_taint)
  - `sensitivity_sources` — all sensitivity contributors (tools + inputs)
  - `capability_drivers` — tools only (unchanged from tool_drivers)

  Only entries with level > :low are included.
  """
  @spec rating_drivers(map(), map()) :: %{
          taint_sources: [%{source: String.t(), level: atom()}],
          sensitivity_sources: [%{source: String.t(), level: atom()}],
          capability_drivers: [%{tool: String.t(), level: atom()}]
        }
  def rating_drivers(definition, all_definitions \\ %{}) do
    has_net = has_network?(definition.network)

    # Tool taint sources
    tool_taint =
      definition.tools
      |> Enum.map(fn tool ->
        level = TaintMatrix.tool_taint(tool)
        level = if tool == "Bash" and has_net, do: :high, else: level
        %{source: tool, level: level}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    # Tool sensitivity sources
    tool_sensitivity =
      definition.tools
      |> Enum.map(fn tool ->
        %{source: tool, level: SensitivityMatrix.tool_sensitivity(tool)}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    # Input sources (from definition.input_sources)
    input_taint =
      Map.get(definition, :input_sources, [])
      |> Enum.map(fn src ->
        %{source: to_string(src), level: TaintMatrix.trigger_taint(src)}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    input_sensitivity =
      Map.get(definition, :input_sources, [])
      |> Enum.map(fn src ->
        %{source: to_string(src), level: SensitivityMatrix.trigger_sensitivity(src)}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    # receive_from peers → :medium taint
    peer_taint =
      definition.receive_from
      |> Enum.map(fn peer -> %{source: "receive_from:#{peer}", level: :medium} end)

    # Network → :high taint
    network_taint =
      if has_net, do: [%{source: "network:outbound", level: :high}], else: []

    # BCP controller channels → step_down(peer_worst_case_taint) for taint,
    # peer sensitivity for sensitivity
    bcp_taint =
      definition.bcp_channels
      |> Enum.filter(fn ch -> ch.role == :controller end)
      |> Enum.map(fn ch ->
        case Map.get(all_definitions, ch.peer) do
          nil -> %{source: "bcp:#{ch.peer}", level: :low}
          peer_def ->
            peer_taint = worst_case_taint(peer_def)
            %{source: "bcp:#{ch.peer}", level: InformationClassifier.step_down(peer_taint)}
        end
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    bcp_sensitivity =
      definition.bcp_channels
      |> Enum.filter(fn ch -> ch.role == :controller end)
      |> Enum.map(fn ch ->
        case Map.get(all_definitions, ch.peer) do
          nil -> %{source: "bcp:#{ch.peer}", level: :low}
          peer_def -> %{source: "bcp:#{ch.peer}", level: worst_case_sensitivity(peer_def)}
        end
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    # base_taint floor
    base_taint_floor = Map.get(definition, :base_taint, :low)
    base_taint_entry =
      if base_taint_floor != :low, do: [%{source: "base_taint", level: base_taint_floor}], else: []

    # Capability drivers (tools only, unchanged)
    capability_drivers =
      definition.tools
      |> Enum.map(fn tool ->
        level = ToolRegistry.capability_level(tool)
        level = if tool == "Bash" and has_net and level == :medium, do: :high, else: level
        %{tool: tool, level: level}
      end)
      |> Enum.filter(fn %{level: l} -> l != :low end)

    %{
      taint_sources: tool_taint ++ input_taint ++ peer_taint ++ network_taint ++ bcp_taint ++ base_taint_entry,
      sensitivity_sources: tool_sensitivity ++ input_sensitivity ++ bcp_sensitivity,
      capability_drivers: capability_drivers
    }
  end

  @doc """
  Validates BCP role symmetry across agent definitions.

  If agent A declares `role: controller` toward B, then B should declare
  `role: reader` toward A. Returns a list of warning maps for mismatches.
  """
  @spec validate_bcp_roles([map()]) :: [map()]
  def validate_bcp_roles(definitions) do
    def_map = Map.new(definitions, &{&1.name, &1})

    for definition <- definitions,
        channel <- Map.get(definition, :bcp_channels, []),
        channel.role == :controller,
        reduce: [] do
      acc ->
        peer_def = Map.get(def_map, channel.peer)

        if peer_def == nil do
          [
            %{
              agent: definition.name,
              peer: channel.peer,
              warning: "BCP channel declares peer '#{channel.peer}' which does not exist"
            }
            | acc
          ]
        else
          peer_channels = Map.get(peer_def, :bcp_channels, [])

          has_reader_decl =
            Enum.any?(peer_channels, fn ch ->
              ch.peer == definition.name and ch.role == :reader
            end)

          if has_reader_decl do
            acc
          else
            [
              %{
                agent: definition.name,
                peer: channel.peer,
                warning:
                  "Agent '#{definition.name}' declares controller role toward '#{channel.peer}', " <>
                    "but '#{channel.peer}' does not declare reader role toward '#{definition.name}'"
              }
              | acc
            ]
          end
        end
    end
  end

  @spec merge_edges(map(), map()) :: map()
  defp merge_edges(edges_a, edges_b) do
    Map.merge(edges_a, edges_b, fn _key, list_a, list_b -> list_a ++ list_b end)
  end

  defp bell_lapadula_fs_violations(definitions, _risk_manifest, sensitivity_levels) do
    network_readers =
      Enum.filter(definitions, fn def ->
        has_network?(def.network)
      end)

    writers =
      Enum.filter(definitions, fn def ->
        def.fs_write != []
      end)

    Enum.flat_map(writers, fn writer ->
      writer_sensitivity = extract_sensitivity(sensitivity_levels, writer.name)

      Enum.flat_map(network_readers, fn reader ->
        reader_sensitivity = extract_sensitivity(sensitivity_levels, reader.name)

        if writer.name != reader.name and level_rank(writer_sensitivity) > level_rank(reader_sensitivity) do
          overlapping = find_overlapping_paths(writer.fs_write, reader.fs_read)

          if overlapping != [] do
            [
              %{
                "writer" => writer.name,
                "reader" => reader.name,
                "paths" => overlapping,
                "edge_type" => "filesystem",
                "description" =>
                  "Sensitivity violation: #{writer.name} (sensitivity: #{writer_sensitivity}) writes to paths " <>
                    "readable by #{reader.name} (sensitivity: #{reader_sensitivity}, network-capable). " <>
                    "Data could be exfiltrated."
              }
            ]
          else
            []
          end
        else
          []
        end
      end)
    end)
  end

  defp bell_lapadula_messaging_violations(definitions, sensitivity_levels) do
    def_map = Map.new(definitions, &{&1.name, &1})

    network_agents =
      definitions
      |> Enum.filter(&has_network?(&1.network))
      |> MapSet.new(& &1.name)

    for sender <- definitions,
        target_name <- Map.get(sender, :send_to, []),
        receiver = Map.get(def_map, target_name),
        receiver != nil,
        sender.name in Map.get(receiver, :receive_from, []),
        sender_sensitivity = extract_sensitivity(sensitivity_levels, sender.name),
        receiver_sensitivity = extract_sensitivity(sensitivity_levels, target_name),
        level_rank(sender_sensitivity) > level_rank(receiver_sensitivity),
        MapSet.member?(network_agents, target_name) do
      %{
        "writer" => sender.name,
        "reader" => target_name,
        "paths" => [],
        "edge_type" => "messaging",
        "description" =>
          "Sensitivity violation: #{sender.name} (sensitivity: #{sender_sensitivity}) can message " <>
            "#{target_name} (sensitivity: #{receiver_sensitivity}, network-capable) via declared messaging link. " <>
            "Data could be exfiltrated."
      }
    end
  end

  @spec find_overlapping_paths([String.t()], [String.t()]) :: [String.t()]
  defp find_overlapping_paths(write_patterns, read_patterns) do
    for write_pat <- write_patterns,
        read_pat <- read_patterns,
        paths_overlap?(write_pat, read_pat),
        reduce: [] do
      acc ->
        overlap_pat = shorter_pattern(write_pat, read_pat)
        [overlap_pat | acc]
    end
    |> Enum.uniq()
  end

  # Two glob patterns overlap if one is a prefix of the other (stripping glob
  # suffixes), or they share a common directory prefix. This is intentionally
  # conservative — it flags potential overlaps for human review.
  @spec paths_overlap?(String.t(), String.t()) :: boolean()
  defp paths_overlap?(pattern_a, pattern_b) do
    dir_a = strip_glob(pattern_a)
    dir_b = strip_glob(pattern_b)

    String.starts_with?(dir_a, dir_b) or
      String.starts_with?(dir_b, dir_a)
  end

  @spec strip_glob(String.t()) :: String.t()
  defp strip_glob(pattern) do
    pattern
    |> String.replace(~r/\*\*.*$/, "")
    |> String.replace(~r/\*.*$/, "")
    |> String.trim_trailing("/")
  end

  @spec shorter_pattern(String.t(), String.t()) :: String.t()
  defp shorter_pattern(a, b) do
    if String.length(a) <= String.length(b), do: a, else: b
  end

  @spec lookup_manifest_taint(String.t(), map()) :: InformationClassifier.information_level()
  defp lookup_manifest_taint(path, risk_manifest) do
    case Map.get(risk_manifest, path) do
      %{"taint_level" => level} -> safe_to_level(level)
      %{"risk_level" => level} -> safe_to_level(level)
      nil -> lookup_prefix_level(path, risk_manifest, "taint_level")
    end
  end

  @spec lookup_manifest_sensitivity(String.t(), map()) :: InformationClassifier.sensitivity_level()
  defp lookup_manifest_sensitivity(path, risk_manifest) do
    case Map.get(risk_manifest, path) do
      %{"sensitivity_level" => level} -> safe_to_level(level)
      _ -> lookup_prefix_level(path, risk_manifest, "sensitivity_level")
    end
  end

  @spec lookup_prefix_level(String.t(), map(), String.t()) :: InformationClassifier.information_level()
  defp lookup_prefix_level(path, risk_manifest, field) do
    risk_manifest
    |> Enum.filter(fn {manifest_path, _} -> paths_overlap?(path, manifest_path) end)
    |> Enum.map(fn {_, entry} -> safe_to_level(Map.get(entry, field, "low")) end)
    |> Enum.reduce(:low, &InformationClassifier.higher_level/2)
  end

  @spec safe_to_level(String.t() | atom()) :: InformationClassifier.information_level()
  defp safe_to_level(:low), do: :low
  defp safe_to_level(:medium), do: :medium
  defp safe_to_level(:high), do: :high
  defp safe_to_level("low"), do: :low
  defp safe_to_level("medium"), do: :medium
  defp safe_to_level("high"), do: :high
  defp safe_to_level(_), do: :low

  @spec has_network?(atom() | [String.t()]) :: boolean()
  defp has_network?(:none), do: false
  defp has_network?(:outbound), do: true
  defp has_network?(hosts) when is_list(hosts) and hosts != [], do: true
  defp has_network?(_), do: false

  @spec level_rank(InformationClassifier.information_level()) :: non_neg_integer()
  defp level_rank(:low), do: 0
  defp level_rank(:medium), do: 1
  defp level_rank(:high), do: 2

end
