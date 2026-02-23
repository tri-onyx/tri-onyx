defmodule TriOnyx.GraphAnalyzerTest do
  use ExUnit.Case, async: true

  alias TriOnyx.AgentDefinition
  alias TriOnyx.GraphAnalyzer

  # Helper to build a minimal agent definition
  defp make_def(attrs) do
    defaults = %{
      description: nil,
      model: "claude-sonnet-4-20250514",
      tools: ["Read"],
      network: :none,
      fs_read: [],
      fs_write: [],
      send_to: [],
      receive_from: [],
      system_prompt: "test prompt",
      heartbeat_every: nil,
      idle_timeout: nil,
      bcp_channels: [],
      input_sources: [],
      base_taint: :low
    }

    merged = Map.merge(defaults, attrs)

    %AgentDefinition{
      name: merged.name,
      description: merged[:description],
      model: merged.model,
      tools: merged.tools,
      network: merged.network,
      fs_read: merged.fs_read,
      fs_write: merged.fs_write,
      send_to: merged.send_to,
      receive_from: merged.receive_from,
      system_prompt: merged.system_prompt,
      heartbeat_every: merged[:heartbeat_every],
      idle_timeout: merged[:idle_timeout],
      bcp_channels: merged.bcp_channels,
      input_sources: merged.input_sources,
      base_taint: merged.base_taint
    }
  end

  describe "analyze/2" do
    test "empty definitions and manifest returns empty map" do
      assert %{} == GraphAnalyzer.analyze([], %{})
    end

    test "two agents with no path overlap produce no edges" do
      agent_a = make_def(%{name: "writer", fs_write: ["/output/a/**"], fs_read: []})
      agent_b = make_def(%{name: "reader", fs_read: ["/input/b/**"], fs_write: []})

      result = GraphAnalyzer.analyze([agent_a, agent_b], %{})

      assert result["writer"].incoming_edges == []
      assert result["reader"].incoming_edges == []
      assert result["writer"].max_input_risk == :low
      assert result["reader"].max_input_risk == :low
      assert result["reader"].max_input_taint == :low
      assert result["reader"].max_input_sensitivity == :low
    end

    test "agent A writes to paths agent B reads creates edge A -> B" do
      agent_a = make_def(%{name: "producer", fs_write: ["src/output/**"], fs_read: []})
      agent_b = make_def(%{name: "consumer", fs_read: ["src/**"], fs_write: []})

      manifest = %{
        "src/output/**" => %{
          "taint_level" => "high",
          "sensitivity_level" => "low",
          "risk_level" => "high",
          "agent" => "producer",
          "updated_at" => "now"
        }
      }

      result = GraphAnalyzer.analyze([agent_a, agent_b], manifest)

      assert length(result["consumer"].incoming_edges) == 1
      edge = hd(result["consumer"].incoming_edges)
      assert edge.from == "producer"
      assert result["consumer"].max_input_taint == :high
      assert result["consumer"].max_input_sensitivity == :low
      assert result["consumer"].max_input_risk == :high

      assert result["producer"].incoming_edges == []
    end

    test "transitive chain A -> B -> C propagates risk" do
      agent_a = make_def(%{name: "source", fs_write: ["/data/raw/**"], fs_read: []})

      agent_b =
        make_def(%{name: "processor", fs_read: ["/data/raw/**"], fs_write: ["/data/processed/**"]})

      agent_c = make_def(%{name: "sink", fs_read: ["/data/processed/**"], fs_write: []})

      manifest = %{
        "/data/raw/**" => %{
          "taint_level" => "high",
          "sensitivity_level" => "low",
          "risk_level" => "high",
          "agent" => "source",
          "updated_at" => "now"
        },
        "/data/processed/**" => %{
          "taint_level" => "medium",
          "sensitivity_level" => "medium",
          "risk_level" => "medium",
          "agent" => "processor",
          "updated_at" => "now"
        }
      }

      result = GraphAnalyzer.analyze([agent_a, agent_b, agent_c], manifest)

      assert result["processor"].max_input_taint == :high
      assert result["sink"].max_input_sensitivity == :medium
      assert result["sink"].max_input_risk == :medium

      chain = result["sink"].risk_chain
      assert "source" in chain
      assert "processor" in chain
    end

    test "single agent with no connections" do
      agent = make_def(%{name: "loner", fs_read: ["/solo/**"], fs_write: ["/solo/out/**"]})

      result = GraphAnalyzer.analyze([agent], %{})

      assert result["loner"].incoming_edges == []
      assert result["loner"].max_input_risk == :low
      assert result["loner"].risk_chain == []
    end
  end

  describe "biba_violations/3 (taint axis)" do
    test "detects low-taint reader consuming high-taint writer output" do
      writer =
        make_def(%{
          name: "web-scraper",
          tools: ["WebFetch"],
          network: :outbound,
          fs_write: ["/data/scraped/**"],
          fs_read: []
        })

      reader =
        make_def(%{
          name: "formatter",
          tools: ["Read"],
              network: :none,
          fs_read: ["/data/scraped/**"],
          fs_write: []
        })

      manifest = %{
        "/data/scraped/**" => %{
          "taint_level" => "high",
          "sensitivity_level" => "low",
          "risk_level" => "high",
          "agent" => "web-scraper",
          "updated_at" => "now"
        }
      }

      analysis = GraphAnalyzer.analyze([writer, reader], manifest)
      # Use two-axis format: taint used for Biba checks
      info_levels = %{
        "web-scraper" => %{taint: :high, sensitivity: :low},
        "formatter" => %{taint: :low, sensitivity: :low}
      }
      violations = GraphAnalyzer.biba_violations(analysis, [writer, reader], info_levels)

      assert length(violations) == 1
      violation = hd(violations)
      assert violation["writer"] == "web-scraper"
      assert violation["reader"] == "formatter"
      assert String.contains?(violation["description"], "Integrity violation")
    end

    test "no violation when taint levels are equal" do
      agent_a =
        make_def(%{
          name: "a",
          tools: ["Read"],
              fs_write: ["/shared/**"],
          fs_read: []
        })

      agent_b =
        make_def(%{
          name: "b",
          tools: ["Read"],
              fs_read: ["/shared/**"],
          fs_write: []
        })

      analysis = GraphAnalyzer.analyze([agent_a, agent_b], %{})
      info_levels = %{
        "a" => %{taint: :medium, sensitivity: :low},
        "b" => %{taint: :medium, sensitivity: :low}
      }
      violations = GraphAnalyzer.biba_violations(analysis, [agent_a, agent_b], info_levels)

      assert violations == []
    end

    test "Biba ignores sensitivity differences" do
      agent_a =
        make_def(%{
          name: "writer",
          tools: ["Write"],
          fs_write: ["/shared/**"],
          fs_read: []
        })

      agent_b =
        make_def(%{
          name: "reader",
          tools: ["Read"],
              fs_read: ["/shared/**"],
          fs_write: []
        })

      analysis = GraphAnalyzer.analyze([agent_a, agent_b], %{})
      # High sensitivity difference, but same taint — should produce no Biba violation
      info_levels = %{
        "writer" => %{taint: :low, sensitivity: :high},
        "reader" => %{taint: :low, sensitivity: :low}
      }
      violations = GraphAnalyzer.biba_violations(analysis, [agent_a, agent_b], info_levels)

      assert violations == []
    end

    test "backward compat: works with single-axis level atoms" do
      agent_a =
        make_def(%{name: "a", fs_write: ["/shared/**"], fs_read: []})

      agent_b =
        make_def(%{name: "b", fs_read: ["/shared/**"], fs_write: []})

      analysis = GraphAnalyzer.analyze([agent_a, agent_b], %{})
      info_levels = %{"a" => :high, "b" => :low}
      violations = GraphAnalyzer.biba_violations(analysis, [agent_a, agent_b], info_levels)

      assert length(violations) == 1
    end
  end

  describe "bell_lapadula_violations/3 (sensitivity axis)" do
    test "detects high-sensitivity writer to lower-sensitivity network reader" do
      writer =
        make_def(%{
          name: "secret-handler",
          tools: ["Read", "Write", "Bash"],
          network: :outbound,
          fs_write: ["/data/secrets/**"],
          fs_read: []
        })

      reader =
        make_def(%{
          name: "reporter",
          tools: ["Read", "WebFetch"],
          network: :outbound,
          fs_read: ["/data/**"],
          fs_write: []
        })

      manifest = %{}
      # Use two-axis format: sensitivity used for BLP checks
      info_levels = %{
        "secret-handler" => %{taint: :low, sensitivity: :high},
        "reporter" => %{taint: :low, sensitivity: :low}
      }

      violations = GraphAnalyzer.bell_lapadula_violations([writer, reader], manifest, info_levels)

      assert length(violations) == 1
      violation = hd(violations)
      assert violation["writer"] == "secret-handler"
      assert violation["reader"] == "reporter"
      assert String.contains?(violation["description"], "Sensitivity violation")
    end

    test "no violation when reader has no network access" do
      writer =
        make_def(%{
          name: "writer",
          tools: ["Write"],
          network: :outbound,
          fs_write: ["/data/**"],
          fs_read: []
        })

      reader =
        make_def(%{
          name: "reader",
          tools: ["Read"],
              network: :none,
          fs_read: ["/data/**"],
          fs_write: []
        })

      info_levels = %{
        "writer" => %{taint: :low, sensitivity: :high},
        "reader" => %{taint: :low, sensitivity: :low}
      }
      violations = GraphAnalyzer.bell_lapadula_violations([writer, reader], %{}, info_levels)

      assert violations == []
    end

    test "BLP ignores taint differences" do
      writer =
        make_def(%{
          name: "tainted-writer",
          tools: ["Write"],
          network: :outbound,
          fs_write: ["/data/**"],
          fs_read: []
        })

      reader =
        make_def(%{
          name: "network-reader",
          tools: ["Read", "WebFetch"],
          network: :outbound,
          fs_read: ["/data/**"],
          fs_write: []
        })

      # High taint difference, but same sensitivity — should produce no BLP violation
      info_levels = %{
        "tainted-writer" => %{taint: :high, sensitivity: :low},
        "network-reader" => %{taint: :low, sensitivity: :low}
      }
      violations = GraphAnalyzer.bell_lapadula_violations([writer, reader], %{}, info_levels)

      assert violations == []
    end
  end

  describe "messaging edges in analyze/2" do
    test "creates messaging edge when both sides declare the link" do
      agent_a = make_def(%{
        name: "main",
        tools: ["Read", "SendMessage"],
        send_to: ["researcher"],
        receive_from: ["researcher"]
      })

      agent_b = make_def(%{
        name: "researcher",
        tools: ["Read", "SendMessage"],
        send_to: ["main"],
        receive_from: ["main"]
      })

      result = GraphAnalyzer.analyze([agent_a, agent_b], %{})

      # main sends to researcher → researcher has incoming messaging edge from main
      researcher_incoming = result["researcher"].incoming_edges
      assert length(researcher_incoming) == 1
      edge = hd(researcher_incoming)
      assert edge.from == "main"
      assert edge.edge_type == :messaging

      # researcher sends to main → main has incoming messaging edge from researcher
      main_incoming = result["main"].incoming_edges
      assert length(main_incoming) == 1
      edge = hd(main_incoming)
      assert edge.from == "researcher"
      assert edge.edge_type == :messaging
    end

    test "no messaging edge when only sender declares" do
      agent_a = make_def(%{
        name: "sender",
        tools: ["Read", "SendMessage"],
        send_to: ["receiver"],
        receive_from: []
      })

      agent_b = make_def(%{
        name: "receiver",
        tools: ["Read"],
        send_to: [],
        receive_from: []
      })

      result = GraphAnalyzer.analyze([agent_a, agent_b], %{})

      assert result["receiver"].incoming_edges == []
    end

    test "no messaging edge when only receiver declares" do
      agent_a = make_def(%{
        name: "sender",
        tools: ["Read", "SendMessage"],
        send_to: [],
        receive_from: []
      })

      agent_b = make_def(%{
        name: "receiver",
        tools: ["Read"],
        send_to: [],
        receive_from: ["sender"]
      })

      result = GraphAnalyzer.analyze([agent_a, agent_b], %{})

      assert result["receiver"].incoming_edges == []
    end
  end

  describe "BLP violations via messaging" do
    test "detects sensitivity violation through messaging link" do
      secret_agent = make_def(%{
        name: "secret-handler",
        tools: ["Read", "SendMessage"],
        send_to: ["reporter"],
        receive_from: []
      })

      reporter = make_def(%{
        name: "reporter",
        tools: ["Read", "WebFetch", "SendMessage"],
        network: :outbound,
        send_to: [],
        receive_from: ["secret-handler"]
      })

      sensitivity_levels = %{
        "secret-handler" => %{taint: :low, sensitivity: :high},
        "reporter" => %{taint: :low, sensitivity: :low}
      }

      violations = GraphAnalyzer.bell_lapadula_violations(
        [secret_agent, reporter], %{}, sensitivity_levels
      )

      msg_violations = Enum.filter(violations, &(&1["edge_type"] == "messaging"))
      assert length(msg_violations) == 1
      violation = hd(msg_violations)
      assert violation["writer"] == "secret-handler"
      assert violation["reader"] == "reporter"
      assert String.contains?(violation["description"], "messaging link")
    end

    test "no messaging BLP violation when receiver has no network" do
      secret_agent = make_def(%{
        name: "secret-handler",
        tools: ["Read", "SendMessage"],
        send_to: ["safe-reader"],
        receive_from: []
      })

      safe_reader = make_def(%{
        name: "safe-reader",
        tools: ["Read", "SendMessage"],
        network: :none,
        send_to: [],
        receive_from: ["secret-handler"]
      })

      sensitivity_levels = %{
        "secret-handler" => %{taint: :low, sensitivity: :high},
        "safe-reader" => %{taint: :low, sensitivity: :low}
      }

      violations = GraphAnalyzer.bell_lapadula_violations(
        [secret_agent, safe_reader], %{}, sensitivity_levels
      )

      msg_violations = Enum.filter(violations, &(&1["edge_type"] == "messaging"))
      assert msg_violations == []
    end
  end

  describe "Biba violations via messaging edges" do
    test "detects integrity violation through messaging edge" do
      tainted = make_def(%{
        name: "tainted-agent",
        tools: ["Read", "WebFetch", "SendMessage"],
        network: :outbound,
        send_to: ["clean-agent"],
        receive_from: []
      })

      clean = make_def(%{
        name: "clean-agent",
        tools: ["Read", "SendMessage"],
        network: :none,
        send_to: [],
        receive_from: ["tainted-agent"]
      })

      analysis = GraphAnalyzer.analyze([tainted, clean], %{})

      info_levels = %{
        "tainted-agent" => %{taint: :high, sensitivity: :low},
        "clean-agent" => %{taint: :low, sensitivity: :low}
      }

      violations = GraphAnalyzer.biba_violations(analysis, [tainted, clean], info_levels)
      assert length(violations) == 1
      violation = hd(violations)
      assert violation["writer"] == "tainted-agent"
      assert violation["reader"] == "clean-agent"
    end
  end

  describe "worst_case_taint/2" do
    test "network agent has high taint" do
      agent = make_def(%{name: "net", network: :outbound})
      assert :high = GraphAnalyzer.worst_case_taint(agent)
    end

    test "WebFetch agent has high taint" do
      agent = make_def(%{name: "fetcher", tools: ["Read", "WebFetch"]})
      assert :high = GraphAnalyzer.worst_case_taint(agent)
    end

    test "agent receiving messages has medium taint" do
      agent = make_def(%{name: "receiver", receive_from: ["other"]})
      assert :medium = GraphAnalyzer.worst_case_taint(agent)
    end

    test "Bash-only agent with no inputs has low taint" do
      agent = make_def(%{name: "bash", tools: ["Read", "Bash"]})
      assert :low = GraphAnalyzer.worst_case_taint(agent)
    end

    test "isolated agent has low taint" do
      agent = make_def(%{name: "reader", network: :none})
      assert :low = GraphAnalyzer.worst_case_taint(agent)
    end

    test "BCP controller inherits step_down of peer taint" do
      # researcher has network → high taint; controller gets step_down(high) = medium
      researcher = make_def(%{name: "researcher", network: :outbound,
        bcp_channels: [%{peer: "main", role: :reader, max_category: 2,
          budget_bits: 500, max_cat2_queries: 10, max_cat3_queries: 0}]})
      main = make_def(%{name: "main", tools: ["Read", "Bash"],
        bcp_channels: [%{peer: "researcher", role: :controller, max_category: 2,
          budget_bits: 500, max_cat2_queries: 10, max_cat3_queries: 0}]})

      all_defs = %{"main" => main, "researcher" => researcher}
      assert :medium = GraphAnalyzer.worst_case_taint(main, all_defs)
    end

    test "BCP controller with low-taint peer stays low" do
      # peer has no external inputs → low taint; step_down(low) = low
      peer = make_def(%{name: "helper", tools: ["Read"]})
      main = make_def(%{name: "main", tools: ["Read", "Bash"],
        bcp_channels: [%{peer: "helper", role: :controller, max_category: 1,
          budget_bits: 100, max_cat2_queries: 0, max_cat3_queries: 0}]})

      all_defs = %{"main" => main, "helper" => peer}
      assert :low = GraphAnalyzer.worst_case_taint(main, all_defs)
    end

    test "BCP without peer context falls back to low" do
      main = make_def(%{name: "main",
        bcp_channels: [%{peer: "unknown", role: :controller, max_category: 2,
          budget_bits: 500, max_cat2_queries: 10, max_cat3_queries: 0}]})

      assert :low = GraphAnalyzer.worst_case_taint(main, %{})
    end
  end

  describe "worst_case_sensitivity/1" do
    test "built-in tools all return low sensitivity" do
      agent = make_def(%{name: "test", tools: ["Read", "Write", "Bash", "WebFetch"]})
      assert :low = GraphAnalyzer.worst_case_sensitivity(agent)
    end
  end

  describe "worst_case_level/1" do
    test "returns max of taint and sensitivity" do
      agent = make_def(%{name: "net", network: :outbound})
      # worst_case_taint = :high, worst_case_sensitivity = :low → max = :high
      assert :high = GraphAnalyzer.worst_case_level(agent)
    end
  end

  describe "trace_risk_chain/3 cycle handling" do
    test "A -> B -> A does not infinite loop" do
      edges = %{
        "A" => [%{from: "B", paths: ["/shared/**"]}],
        "B" => [%{from: "A", paths: ["/shared/**"]}]
      }

      chain_a = GraphAnalyzer.trace_risk_chain("A", edges, MapSet.new())
      chain_b = GraphAnalyzer.trace_risk_chain("B", edges, MapSet.new())

      assert is_list(chain_a)
      assert is_list(chain_b)
      assert "B" in chain_a
    end
  end

  describe "BCP edges in analyze/2" do
    test "creates bcp edge from reader to controller" do
      controller = make_def(%{
        name: "controller",
        tools: ["Read", "SendMessage"],
        bcp_channels: [
          %{peer: "reader", role: :controller, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      reader = make_def(%{
        name: "reader",
        tools: ["Read"],
        bcp_channels: [
          %{peer: "controller", role: :reader, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      result = GraphAnalyzer.analyze([controller, reader], %{})

      controller_incoming = result["controller"].incoming_edges
      assert length(controller_incoming) == 1
      edge = hd(controller_incoming)
      assert edge.from == "reader"
      assert edge.edge_type == :bcp

      # Reader has no incoming bcp edges (only controller receives)
      assert result["reader"].incoming_edges == []
    end

    test "no bcp edge when peer does not exist" do
      controller = make_def(%{
        name: "ctrl",
        bcp_channels: [
          %{peer: "nonexistent", role: :controller, max_category: 1, budget_bits: 100,
            max_cat2_queries: 0, max_cat3_queries: 0}
        ]
      })

      result = GraphAnalyzer.analyze([controller], %{})
      assert result["ctrl"].incoming_edges == []
    end
  end

  describe "validate_bcp_roles/1" do
    test "returns empty list when roles are symmetric" do
      controller = make_def(%{
        name: "ctrl",
        bcp_channels: [
          %{peer: "rdr", role: :controller, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      reader = make_def(%{
        name: "rdr",
        bcp_channels: [
          %{peer: "ctrl", role: :reader, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      assert [] == GraphAnalyzer.validate_bcp_roles([controller, reader])
    end

    test "warns when peer does not declare reader role" do
      controller = make_def(%{
        name: "ctrl",
        bcp_channels: [
          %{peer: "rdr", role: :controller, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      reader = make_def(%{name: "rdr", bcp_channels: []})

      warnings = GraphAnalyzer.validate_bcp_roles([controller, reader])
      assert length(warnings) == 1
      assert hd(warnings).agent == "ctrl"
      assert hd(warnings).peer == "rdr"
      assert hd(warnings).warning =~ "does not declare reader role"
    end

    test "warns when peer does not exist" do
      controller = make_def(%{
        name: "ctrl",
        bcp_channels: [
          %{peer: "ghost", role: :controller, max_category: 1, budget_bits: 100,
            max_cat2_queries: 0, max_cat3_queries: 0}
        ]
      })

      warnings = GraphAnalyzer.validate_bcp_roles([controller])
      assert length(warnings) == 1
      assert hd(warnings).warning =~ "does not exist"
    end

    test "ignores reader-only declarations (no symmetry check needed)" do
      reader = make_def(%{
        name: "rdr",
        bcp_channels: [
          %{peer: "ctrl", role: :reader, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      assert [] == GraphAnalyzer.validate_bcp_roles([reader])
    end
  end

  describe "propagate_levels/3" do
    test "transitive propagation A→B→C propagates taint through chain" do
      agent_a = make_def(%{name: "source", fs_write: ["/data/raw/**"], fs_read: []})
      agent_b = make_def(%{name: "middle", fs_read: ["/data/raw/**"], fs_write: ["/data/out/**"]})
      agent_c = make_def(%{name: "sink", fs_read: ["/data/out/**"], fs_write: []})

      manifest = %{
        "/data/raw/**" => %{"taint_level" => "low", "sensitivity_level" => "low", "risk_level" => "low"},
        "/data/out/**" => %{"taint_level" => "low", "sensitivity_level" => "low", "risk_level" => "low"}
      }

      definitions = [agent_a, agent_b, agent_c]
      fs_edges = build_edges_for_test(definitions, manifest)

      base_levels = %{
        "source" => %{taint: :high, sensitivity: :low},
        "middle" => %{taint: :low, sensitivity: :low},
        "sink" => %{taint: :low, sensitivity: :low}
      }

      result = GraphAnalyzer.propagate_levels(definitions, fs_edges, base_levels)

      assert result["middle"].taint == :high
      assert result["sink"].taint == :high
      assert result["sink"].sensitivity == :low
    end

    test "BCP edge applies step_down on taint" do
      controller = make_def(%{
        name: "ctrl",
        bcp_channels: [%{peer: "rdr", role: :controller, max_category: 2,
          budget_bits: 500, max_cat2_queries: 5, max_cat3_queries: 0}]
      })
      reader = make_def(%{
        name: "rdr",
        bcp_channels: [%{peer: "ctrl", role: :reader, max_category: 2,
          budget_bits: 500, max_cat2_queries: 5, max_cat3_queries: 0}]
      })

      definitions = [controller, reader]
      # BCP edge: reader → controller
      edges = %{"ctrl" => [%{from: "rdr", paths: [], edge_type: :bcp}]}

      base_levels = %{
        "ctrl" => %{taint: :low, sensitivity: :low},
        "rdr" => %{taint: :high, sensitivity: :medium}
      }

      result = GraphAnalyzer.propagate_levels(definitions, edges, base_levels)

      # step_down(:high) = :medium for taint via BCP
      assert result["ctrl"].taint == :medium
      # sensitivity passes through unchanged
      assert result["ctrl"].sensitivity == :medium
    end

    test "BCP edge does NOT step down sensitivity" do
      ctrl = make_def(%{name: "ctrl"})
      rdr = make_def(%{name: "rdr"})

      edges = %{"ctrl" => [%{from: "rdr", paths: [], edge_type: :bcp}]}
      base_levels = %{
        "ctrl" => %{taint: :low, sensitivity: :low},
        "rdr" => %{taint: :low, sensitivity: :high}
      }

      result = GraphAnalyzer.propagate_levels([ctrl, rdr], edges, base_levels)
      assert result["ctrl"].sensitivity == :high
    end

    test "tracks taint_sources correctly" do
      a = make_def(%{name: "a"})
      b = make_def(%{name: "b"})

      edges = %{"b" => [%{from: "a", paths: [], edge_type: :filesystem}]}
      base_levels = %{
        "a" => %{taint: :high, sensitivity: :low},
        "b" => %{taint: :low, sensitivity: :low}
      }

      result = GraphAnalyzer.propagate_levels([a, b], edges, base_levels)
      assert length(result["b"].taint_sources) == 1
      assert hd(result["b"].taint_sources).from == "a"
      assert hd(result["b"].taint_sources).contributed == :high
    end

    test "monotonic convergence with cycle" do
      a = make_def(%{name: "a"})
      b = make_def(%{name: "b"})

      edges = %{
        "a" => [%{from: "b", paths: [], edge_type: :filesystem}],
        "b" => [%{from: "a", paths: [], edge_type: :filesystem}]
      }
      base_levels = %{
        "a" => %{taint: :high, sensitivity: :low},
        "b" => %{taint: :low, sensitivity: :medium}
      }

      result = GraphAnalyzer.propagate_levels([a, b], edges, base_levels)
      assert result["a"].taint == :high
      assert result["b"].taint == :high
      assert result["a"].sensitivity == :medium
      assert result["b"].sensitivity == :medium
    end
  end

  # Helper to build edges for propagate_levels tests
  defp build_edges_for_test(definitions, risk_manifest) do
    # Replicate the edge building from analyze/2
    # Simple: just call analyze and extract edges from incoming_edges
    analysis = GraphAnalyzer.analyze(definitions, risk_manifest)
    for {name, %{incoming_edges: edges}} <- analysis, into: %{} do
      {name, edges}
    end
  end

  describe "tool_drivers/1" do
    test "returns taint drivers for tools with taint > low" do
      agent = make_def(%{name: "fetcher", tools: ["Read", "WebFetch", "WebSearch"], network: :none})
      result = GraphAnalyzer.tool_drivers(agent)

      assert length(result.taint_drivers) == 2
      tools = Enum.map(result.taint_drivers, & &1.tool)
      assert "WebFetch" in tools
      assert "WebSearch" in tools
    end

    test "Bash promoted to high taint and capability with network" do
      agent = make_def(%{name: "basher", tools: ["Read", "Bash"], network: :outbound})
      result = GraphAnalyzer.tool_drivers(agent)

      bash_taint = Enum.find(result.taint_drivers, &(&1.tool == "Bash"))
      assert bash_taint.level == :high

      bash_cap = Enum.find(result.capability_drivers, &(&1.tool == "Bash"))
      assert bash_cap.level == :high
    end

    test "Bash without network stays at base levels" do
      agent = make_def(%{name: "basher", tools: ["Read", "Bash"], network: :none})
      result = GraphAnalyzer.tool_drivers(agent)

      # Bash taint is :low without network, so not in drivers
      assert Enum.find(result.taint_drivers, &(&1.tool == "Bash")) == nil

      bash_cap = Enum.find(result.capability_drivers, &(&1.tool == "Bash"))
      assert bash_cap.level == :medium
    end

    test "returns empty lists for all-low tools" do
      agent = make_def(%{name: "reader", tools: ["Read", "Grep", "Glob"]})
      result = GraphAnalyzer.tool_drivers(agent)

      assert result.taint_drivers == []
      assert result.sensitivity_drivers == []
      assert result.capability_drivers == []
    end
  end

  describe "BCP edge metadata" do
    test "BCP edges include max_category and budget_bits" do
      controller = make_def(%{
        name: "ctrl",
        bcp_channels: [
          %{peer: "rdr", role: :controller, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      reader = make_def(%{
        name: "rdr",
        bcp_channels: [
          %{peer: "ctrl", role: :reader, max_category: 2, budget_bits: 500,
            max_cat2_queries: 5, max_cat3_queries: 0}
        ]
      })

      result = GraphAnalyzer.analyze([controller, reader], %{})
      edge = hd(result["ctrl"].incoming_edges)
      assert edge.max_category == 2
      assert edge.budget_bits == 500
    end
  end

  describe "worst_case_taint with input_sources" do
    test "connector_unverified raises taint to high" do
      agent = make_def(%{name: "cal", tools: ["Read", "CalendarQuery"], input_sources: [:connector_unverified]})
      assert :high = GraphAnalyzer.worst_case_taint(agent)
    end

    test "webhook raises taint to high" do
      agent = make_def(%{name: "wh", tools: ["Read"], input_sources: [:webhook]})
      assert :high = GraphAnalyzer.worst_case_taint(agent)
    end

    test "cron does not raise taint" do
      agent = make_def(%{name: "cron", tools: ["Read"], input_sources: [:cron]})
      assert :low = GraphAnalyzer.worst_case_taint(agent)
    end
  end

  describe "worst_case_sensitivity with input_sources" do
    test "connector_unverified raises sensitivity to medium" do
      agent = make_def(%{name: "cal", tools: ["Read"], input_sources: [:connector_unverified]})
      assert :medium = GraphAnalyzer.worst_case_sensitivity(agent)
    end

    test "webhook does not raise sensitivity" do
      agent = make_def(%{name: "wh", tools: ["Read"], input_sources: [:webhook]})
      assert :low = GraphAnalyzer.worst_case_sensitivity(agent)
    end
  end

  describe "rating_drivers/2" do
    test "includes tool and input source taint" do
      agent = make_def(%{name: "cal", tools: ["Read", "WebFetch"], input_sources: [:connector_unverified]})
      result = GraphAnalyzer.rating_drivers(agent)

      sources = Enum.map(result.taint_sources, & &1.source)
      assert "WebFetch" in sources
      assert "connector_unverified" in sources
    end

    test "includes receive_from peers as taint sources" do
      agent = make_def(%{name: "a", tools: ["Read"], receive_from: ["main"]})
      result = GraphAnalyzer.rating_drivers(agent)

      sources = Enum.map(result.taint_sources, & &1.source)
      assert "receive_from:main" in sources
    end

    test "includes network as taint source" do
      agent = make_def(%{name: "a", tools: ["Read"], network: :outbound})
      result = GraphAnalyzer.rating_drivers(agent)

      sources = Enum.map(result.taint_sources, & &1.source)
      assert "network:outbound" in sources
    end

    test "includes base_taint when above low" do
      agent = make_def(%{name: "a", tools: ["Read"], base_taint: :medium})
      result = GraphAnalyzer.rating_drivers(agent)

      sources = Enum.map(result.taint_sources, & &1.source)
      assert "base_taint" in sources
    end

    test "excludes base_taint when low" do
      agent = make_def(%{name: "a", tools: ["Read"], base_taint: :low})
      result = GraphAnalyzer.rating_drivers(agent)

      sources = Enum.map(result.taint_sources, & &1.source)
      refute "base_taint" in sources
    end

    test "includes input source sensitivity" do
      agent = make_def(%{name: "cal", tools: ["Read"], input_sources: [:connector_unverified]})
      result = GraphAnalyzer.rating_drivers(agent)

      sources = Enum.map(result.sensitivity_sources, & &1.source)
      assert "connector_unverified" in sources
    end

    test "capability_drivers only include tools" do
      agent = make_def(%{name: "a", tools: ["Read", "Bash"], input_sources: [:webhook]})
      result = GraphAnalyzer.rating_drivers(agent)

      # capability_drivers should only have tools, not input sources
      assert Enum.all?(result.capability_drivers, fn d -> Map.has_key?(d, :tool) end)
    end
  end

end
