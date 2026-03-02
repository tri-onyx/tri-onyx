defmodule TriOnyx.AgentDefinitionTest do
  use ExUnit.Case, async: true

  alias TriOnyx.AgentDefinition

  @valid_definition """
  ---
  name: code-reviewer
  description: Reviews code for quality issues
  model: claude-sonnet-4-20250514
  tools: Read, Grep, Glob
  network: none
  fs_read:
    - "/workspace/repo/src/**/*.py"
    - "/workspace/repo/docs/**/*.md"
  fs_write:
    - "/workspace/repo/src/output/**"
  ---

  You are a code reviewer. Analyze code for quality issues and report findings.
  """

  @minimal_definition """
  ---
  name: simple-agent
  tools: Read
  ---

  A simple agent.
  """

  describe "parse/1" do
    test "parses a complete agent definition" do
      assert {:ok, def} = AgentDefinition.parse(@valid_definition)

      assert def.name == "code-reviewer"
      assert def.description == "Reviews code for quality issues"
      assert def.model == "claude-sonnet-4-20250514"
      assert def.tools == ["Read", "Grep", "Glob"]
      assert def.network == :none
      assert def.fs_read == ["/workspace/repo/src/**/*.py", "/workspace/repo/docs/**/*.md"]
      assert def.fs_write == ["/workspace/repo/src/output/**"]
      assert def.system_prompt =~ "You are a code reviewer"
    end

    test "parses a minimal definition with defaults" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)

      assert def.name == "simple-agent"
      assert def.description == nil
      assert def.model == "claude-sonnet-4-20250514"
      assert def.tools == ["Read"]
      assert def.network == :none
      assert def.fs_read == []
      assert def.fs_write == []
      assert def.send_to == []
      assert def.receive_from == []
      assert def.system_prompt == "A simple agent."
    end

    test "parses tools as YAML list" do
      content = """
      ---
      name: list-tools-agent
      tools:
        - Read
        - Write
        - Bash
      ---

      Agent with list tools.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.tools == ["Read", "Write", "Bash"]
    end

    test "accepts full claude model IDs" do
      for model <- ~w(claude-sonnet-4-20250514 claude-haiku-4-5 claude-opus-4-20250514) do
        content = """
        ---
        name: test-agent
        tools: Read
        model: #{model}
        ---

        Test.
        """

        assert {:ok, def} = AgentDefinition.parse(content)
        assert def.model == model
      end
    end

    test "parses network: outbound" do
      content = """
      ---
      name: net-agent
      tools: WebFetch
      network: outbound
      ---

      Fetches web content.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.network == :outbound
    end

    test "parses network as host allowlist" do
      content = """
      ---
      name: net-agent
      tools: WebFetch
      network:
        - api.github.com
        - hooks.slack.com
      ---

      Fetches from specific hosts.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.network == ["api.github.com", "hooks.slack.com"]
    end

    test "rejects wildcard network host patterns" do
      content = """
      ---
      name: wildcard-agent
      tools: WebFetch
      network:
        - api.github.com
        - "*.slack.com"
      ---

      Wildcard host.
      """

      assert {:error, {:wildcard_network_hosts, ["*.slack.com"], msg}} =
               AgentDefinition.parse(content)

      assert msg =~ "iptables"
    end

    test "returns error for missing frontmatter delimiters" do
      assert {:error, :invalid_format} = AgentDefinition.parse("no frontmatter here")
    end

    test "returns error for missing name" do
      content = """
      ---
      tools: Read
      ---

      Missing name.
      """

      assert {:error, {:missing_required_field, "name"}} = AgentDefinition.parse(content)
    end

    test "returns error for missing tools" do
      content = """
      ---
      name: no-tools
      ---

      Missing tools.
      """

      assert {:error, {:missing_required_field, "tools"}} = AgentDefinition.parse(content)
    end

    test "rejects non-claude model IDs" do
      content = """
      ---
      name: bad-model
      tools: Read
      model: gpt-4
      ---

      Bad model.
      """

      assert {:error, {:invalid_model, "gpt-4", _msg}} = AgentDefinition.parse(content)
    end

    test "returns error for unknown tools" do
      content = """
      ---
      name: unknown-tools
      tools: Read, FakeInstrument
      ---

      Unknown tool.
      """

      assert {:error, {:unknown_tools, ["FakeInstrument"]}} = AgentDefinition.parse(content)
    end

    test "returns error for invalid network policy string" do
      content = """
      ---
      name: bad-net
      tools: Read
      network: inbound
      ---

      Bad network.
      """

      assert {:error, {:invalid_network_policy, "inbound"}} = AgentDefinition.parse(content)
    end

    test "returns error for empty tools string" do
      content = """
      ---
      name: empty-tools
      tools: ""
      ---

      Empty tools.
      """

      assert {:error, {:empty_tools_list}} = AgentDefinition.parse(content)
    end
  end

  describe "heartbeat_every parsing" do
    test "parses minutes duration" do
      content = """
      ---
      name: hb-agent
      tools: Read
      heartbeat_every: 30m
      ---

      Heartbeat agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.heartbeat_every == 1_800_000
    end

    test "parses seconds duration" do
      content = """
      ---
      name: hb-agent
      tools: Read
      heartbeat_every: 60s
      ---

      Heartbeat agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.heartbeat_every == 60_000
    end

    test "parses hours duration" do
      content = """
      ---
      name: hb-agent
      tools: Read
      heartbeat_every: 1h
      ---

      Heartbeat agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.heartbeat_every == 3_600_000
    end

    test "defaults to nil when not specified" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.heartbeat_every == nil
    end

    test "rejects invalid duration format" do
      content = """
      ---
      name: hb-agent
      tools: Read
      heartbeat_every: 30x
      ---

      Bad duration.
      """

      assert {:error, {:invalid_duration_format, "30x", _}} = AgentDefinition.parse(content)
    end

    test "accepts raw integer milliseconds" do
      content = """
      ---
      name: hb-agent
      tools: Read
      heartbeat_every: 45000
      ---

      Raw ms.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.heartbeat_every == 45_000
    end
  end

  describe "send_to/receive_from parsing" do
    test "parses send_to and receive_from lists" do
      content = """
      ---
      name: msg-agent
      tools: Read, SendMessage
      send_to:
        - researcher
        - reviewer
      receive_from:
        - researcher
      ---

      Messaging agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.send_to == ["researcher", "reviewer"]
      assert def.receive_from == ["researcher"]
    end

    test "defaults to empty lists when omitted" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.send_to == []
      assert def.receive_from == []
    end

    test "logs warning when SendMessage tool present but no peers declared" do
      import ExUnit.CaptureLog

      content = """
      ---
      name: lonely-sender
      tools: Read, SendMessage
      ---

      No peers.
      """

      log =
        capture_log(fn ->
          assert {:ok, _def} = AgentDefinition.parse(content)
        end)

      assert log =~ "lonely-sender"
      assert log =~ "no send_to/receive_from peers declared"
    end

    test "no warning when SendMessage absent even without peers" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert {:ok, _def} = AgentDefinition.parse(@minimal_definition)
        end)

      refute log =~ "send_to/receive_from"
    end
  end

  describe "idle_timeout parsing" do
    test "parses minutes duration" do
      content = """
      ---
      name: idle-agent
      tools: Read
      idle_timeout: 5m
      ---

      Idle timeout agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.idle_timeout == 300_000
    end

    test "parses seconds duration" do
      content = """
      ---
      name: idle-agent
      tools: Read
      idle_timeout: 30s
      ---

      Idle timeout agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.idle_timeout == 30_000
    end

    test "defaults to nil when not specified" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.idle_timeout == nil
    end

    test "rejects invalid duration format" do
      content = """
      ---
      name: idle-agent
      tools: Read
      idle_timeout: 30x
      ---

      Bad duration.
      """

      assert {:error, {:invalid_duration_format, "30x", _}} = AgentDefinition.parse(content)
    end
  end

  describe "bcp_channels parsing" do
    test "parses valid bcp_channels" do
      content = """
      ---
      name: controller-agent
      tools: Read, SendMessage
      bcp_channels:
        - peer: researcher
          role: controller
          max_category: 2
          budget_bits: 500
          max_cat2_queries: 5
          max_cat3_queries: 0
      ---

      Controller agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert length(def.bcp_channels) == 1

      channel = hd(def.bcp_channels)
      assert channel.peer == "researcher"
      assert channel.role == :controller
      assert channel.max_category == 2
      assert channel.budget_bits == 500
      assert channel.max_cat2_queries == 5
      assert channel.max_cat3_queries == 0
    end

    test "defaults bcp_channels to empty list" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.bcp_channels == []
    end

    test "parses multiple channels" do
      content = """
      ---
      name: orchestrator
      tools: Read, SendMessage
      bcp_channels:
        - peer: researcher
          role: controller
          max_category: 2
          budget_bits: 500
          max_cat2_queries: 5
          max_cat3_queries: 0
        - peer: scanner
          role: reader
          max_category: 1
          budget_bits: 100
      ---

      Orchestrator.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert length(def.bcp_channels) == 2
      assert Enum.at(def.bcp_channels, 0).peer == "researcher"
      assert Enum.at(def.bcp_channels, 1).peer == "scanner"
      assert Enum.at(def.bcp_channels, 1).role == :reader
    end

    test "defaults max_cat2_queries and max_cat3_queries to 0" do
      content = """
      ---
      name: agent
      tools: Read
      bcp_channels:
        - peer: other
          role: controller
          max_category: 1
          budget_bits: 100
      ---

      Agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      channel = hd(def.bcp_channels)
      assert channel.max_cat2_queries == 0
      assert channel.max_cat3_queries == 0
    end

    test "rejects invalid role" do
      content = """
      ---
      name: agent
      tools: Read
      bcp_channels:
        - peer: other
          role: supervisor
          max_category: 1
          budget_bits: 100
      ---

      Agent.
      """

      assert {:error, {:invalid_bcp_role, 0, "supervisor", _}} = AgentDefinition.parse(content)
    end

    test "rejects invalid max_category" do
      content = """
      ---
      name: agent
      tools: Read
      bcp_channels:
        - peer: other
          role: controller
          max_category: 5
          budget_bits: 100
      ---

      Agent.
      """

      assert {:error, {:invalid_bcp_max_category, 0, 5, _}} = AgentDefinition.parse(content)
    end

    test "rejects missing peer field" do
      content = """
      ---
      name: agent
      tools: Read
      bcp_channels:
        - role: controller
          max_category: 1
          budget_bits: 100
      ---

      Agent.
      """

      assert {:error, {:missing_bcp_channel_field, 0, "peer"}} = AgentDefinition.parse(content)
    end

    test "rejects zero budget_bits" do
      content = """
      ---
      name: agent
      tools: Read
      bcp_channels:
        - peer: other
          role: controller
          max_category: 1
          budget_bits: 0
      ---

      Agent.
      """

      assert {:error, {:invalid_bcp_channel_field, 0, "budget_bits", :must_be_positive}} =
               AgentDefinition.parse(content)
    end
  end

  describe "cron_schedules parsing" do
    test "defaults to empty list when not specified" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.cron_schedules == []
    end

    test "parses valid cron_schedules" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules:
        - schedule: "0 9 * * 1-5"
          message: "Good morning!"
          label: morning-standup
        - schedule: "0 17 * * 5"
          message: "End of week summary"
      ---

      Cron agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert length(def.cron_schedules) == 2

      [first, second] = def.cron_schedules
      assert first.schedule == "0 9 * * 1-5"
      assert first.message == "Good morning!"
      assert first.label == "morning-standup"

      assert second.schedule == "0 17 * * 5"
      assert second.message == "End of week summary"
      assert second.label == nil
    end

    test "parses cron entry without label" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules:
        - schedule: "*/5 * * * *"
          message: "Every 5 minutes"
      ---

      Cron agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      [entry] = def.cron_schedules
      assert entry.label == nil
    end

    test "rejects invalid cron expression" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules:
        - schedule: "not a cron"
          message: "Will fail"
      ---

      Cron agent.
      """

      assert {:error, {:invalid_cron_schedule, 0, {:invalid_expression, _}}} =
               AgentDefinition.parse(content)
    end

    test "rejects entry missing schedule field" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules:
        - message: "No schedule"
      ---

      Cron agent.
      """

      assert {:error, {:invalid_cron_schedule, 0, {:missing_field, "schedule"}}} =
               AgentDefinition.parse(content)
    end

    test "rejects entry missing message field" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules:
        - schedule: "0 * * * *"
      ---

      Cron agent.
      """

      assert {:error, {:invalid_cron_schedule, 0, {:missing_field, "message"}}} =
               AgentDefinition.parse(content)
    end

    test "reports correct index for second failing entry" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules:
        - schedule: "0 9 * * *"
          message: "Valid"
        - schedule: "bad expression"
          message: "Invalid"
      ---

      Cron agent.
      """

      assert {:error, {:invalid_cron_schedule, 1, {:invalid_expression, _}}} =
               AgentDefinition.parse(content)
    end

    test "rejects cron_schedules that is not a list" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules: "not a list"
      ---

      Cron agent.
      """

      assert {:error, {:invalid_field_type, "cron_schedules", :expected_list}} =
               AgentDefinition.parse(content)
    end
  end

  describe "input_sources parsing" do
    test "parses valid input_sources" do
      content = """
      ---
      name: cal-agent
      tools: Read
      input_sources:
        - unverified_input
        - webhook
      ---

      Calendar agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.input_sources == [:unverified_input, :webhook]
    end

    test "defaults to empty list when not specified" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.input_sources == []
    end

    test "rejects invalid input source values" do
      content = """
      ---
      name: bad-agent
      tools: Read
      input_sources:
        - invalid_source
      ---

      Bad agent.
      """

      assert {:error, {:invalid_input_sources, ["invalid_source"], _}} =
               AgentDefinition.parse(content)
    end

    test "auto-includes :cron when cron_schedules present" do
      content = """
      ---
      name: cron-agent
      tools: Read
      cron_schedules:
        - schedule: "0 9 * * *"
          message: "Morning"
      ---

      Cron agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert :cron in def.input_sources
    end

    test "does not duplicate :cron when already declared" do
      content = """
      ---
      name: cron-agent
      tools: Read
      input_sources:
        - cron
      cron_schedules:
        - schedule: "0 9 * * *"
          message: "Morning"
      ---

      Cron agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert Enum.count(def.input_sources, &(&1 == :cron)) == 1
    end
  end

  describe "browser parsing" do
    test "defaults to false when not specified" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.browser == false
    end

    test "parses browser: true" do
      content = """
      ---
      name: browser-agent
      tools: Read, Bash
      browser: true
      network: outbound
      ---

      Browser agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.browser == true
    end

    test "parses browser: false" do
      content = """
      ---
      name: no-browser
      tools: Read
      browser: false
      ---

      No browser.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.browser == false
    end

    test "rejects non-boolean browser value" do
      content = """
      ---
      name: bad-browser
      tools: Read
      browser: "yes"
      ---

      Bad browser.
      """

      assert {:error, {:invalid_field_type, "browser", :expected_boolean}} =
               AgentDefinition.parse(content)
    end

    test "logs warning when browser: true with network: none" do
      import ExUnit.CaptureLog

      content = """
      ---
      name: offline-browser
      tools: Read, Bash
      browser: true
      network: none
      ---

      Offline browser.
      """

      log =
        capture_log(fn ->
          assert {:ok, _def} = AgentDefinition.parse(content)
        end)

      assert log =~ "offline-browser"
      assert log =~ "network: none"
    end

    test "logs warning when browser: true without Bash tool" do
      import ExUnit.CaptureLog

      content = """
      ---
      name: no-bash-browser
      tools: Read
      browser: true
      network: outbound
      ---

      No bash browser.
      """

      log =
        capture_log(fn ->
          assert {:ok, _def} = AgentDefinition.parse(content)
        end)

      assert log =~ "no-bash-browser"
      assert log =~ "Bash is not in tools"
    end
  end

  describe "plugins parsing" do
    test "parses plugins list" do
      content = """
      ---
      name: plugin-agent
      tools: Read
      plugins:
        - newsagg
        - diary
      ---

      Plugin agent.
      """

      assert {:ok, def} = AgentDefinition.parse(content)
      assert def.plugins == ["newsagg", "diary"]
    end

    test "defaults to empty list when not specified" do
      assert {:ok, def} = AgentDefinition.parse(@minimal_definition)
      assert def.plugins == []
    end
  end

  describe "parse!/1" do
    test "returns definition on success" do
      assert %AgentDefinition{name: "simple-agent"} = AgentDefinition.parse!(@minimal_definition)
    end

    test "raises on error" do
      assert_raise ArgumentError, ~r/Failed to parse/, fn ->
        AgentDefinition.parse!("invalid content")
      end
    end
  end
end
