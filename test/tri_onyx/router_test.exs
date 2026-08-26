defmodule TriOnyx.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.Router
  alias TriOnyx.TriggerRouter

  @test_definition %AgentDefinition{
    name: "test-agent",
    description: "A test agent",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Grep"],
    network: :none,
    repos_read: ["core"],
    system_prompt: "You are a test agent."
  }

  setup do
    # The application supervision tree may already have these running.
    # Use existing processes if available, otherwise start fresh.
    {sup_pid, sup_owned} = ensure_started(AgentSupervisor, fn ->
      AgentSupervisor.start_link(name: AgentSupervisor)
    end)

    {router_pid, router_owned} = ensure_started(TriggerRouter, fn ->
      TriggerRouter.start_link(definitions: [@test_definition])
    end)

    # Register the test definition if using an already-running router
    unless router_owned do
      TriggerRouter.register_agent(@test_definition)
    end

    on_exit(fn ->
      if router_owned, do: safe_stop(router_pid)
      if sup_owned, do: safe_stop(sup_pid)
    end)

    :ok
  end

  defp ensure_started(name, start_fn) do
    case Process.whereis(name) do
      nil ->
        {:ok, pid} = start_fn.()
        {pid, true}

      pid ->
        {pid, false}
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp call_router(conn) do
    Router.call(conn, Router.init([]))
  end

  describe "GET /health" do
    test "returns 200 with status" do
      conn = conn(:get, "/health") |> call_router()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert is_integer(body["active_sessions"])
    end
  end

  describe "GET /agents" do
    test "lists registered agents" do
      conn = conn(:get, "/agents") |> call_router()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["agents"])
      assert length(body["agents"]) >= 1

      agent = Enum.find(body["agents"], &(&1["name"] == "test-agent"))
      assert agent, "expected test-agent in agents list"
      assert agent["status"] == "inactive"
    end
  end

  describe "GET /agents/:name" do
    test "returns agent detail for known agent" do
      conn = conn(:get, "/agents/test-agent") |> call_router()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "test-agent"
      assert body["tools"] == ["Read", "Grep"]
      assert body["repos_read"] == ["core"]
      assert body["status"] == "inactive"
    end

    test "returns 404 for unknown agent" do
      conn = conn(:get, "/agents/nonexistent") |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "agent_not_found"
    end
  end

  describe "GET /agents/schema" do
    test "exposes the full risk model (levels, ordering, matrix, capability rule)" do
      conn = conn(:get, "/agents/schema") |> call_router()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      model = body["risk_model"]
      assert is_map(model)
      assert is_list(model["risk_matrix"])

      # Taint/sensitivity level ordering sourced from InformationClassifier.
      expected_levels = Enum.map(TriOnyx.InformationClassifier.levels(), &to_string/1)
      assert model["levels"] == expected_levels
      assert model["levels"] == ["low", "medium", "high"]

      # Risk severity ordering sourced from RiskScorer.
      expected_risk_levels = Enum.map(TriOnyx.RiskScorer.risk_levels(), &to_string/1)
      assert model["risk_levels"] == expected_risk_levels
      assert model["risk_levels"] == ["low", "moderate", "high", "critical"]

      # 2D matrix is served under the model, matching RiskScorer.risk_matrix/0.
      assert length(model["risk_matrix"]) == map_size(TriOnyx.RiskScorer.risk_matrix())

      # Capability adjustment matches RiskScorer.capability_adjustment/0 exactly.
      cap = model["capability_adjustment"]
      assert is_map(cap)

      for {capability, mapping} <- TriOnyx.RiskScorer.capability_adjustment() do
        for {baseline, adjusted} <- mapping do
          assert cap[to_string(capability)][to_string(baseline)] == to_string(adjusted),
                 "capability_adjustment drift for #{capability}/#{baseline}"
        end
      end

      # Spot-check the documented rule, including the low-baseline exception:
      # high capability does NOT step a :low baseline up.
      assert cap["high"]["low"] == "low"
      assert cap["high"]["moderate"] == "high"
      assert cap["low"]["critical"] == "high"
      assert cap["medium"]["high"] == "high"
    end
  end

  describe "POST /webhooks/:agent_name" do
    test "rejects invalid JSON" do
      conn =
        conn(:post, "/webhooks/test-agent", "not json")
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_json"
    end

    test "returns 404 for unknown agent" do
      conn =
        conn(:post, "/webhooks/nonexistent", Jason.encode!(%{"event" => "test"}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unknown_agent"
    end
  end

  describe "POST /messages" do
    test "rejects missing authorization" do
      payload = Jason.encode!(%{"agent" => "test-agent", "content" => "hello"})

      conn =
        conn(:post, "/messages", payload)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unauthorized"
    end

    test "rejects invalid JSON" do
      conn =
        conn(:post, "/messages", "not json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer test-key")
        |> call_router()

      assert conn.status == 400
    end
  end

  describe "POST /agents/:name/stop" do
    test "returns 404 when no active session" do
      conn =
        conn(:post, "/agents/test-agent/stop", "")
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "no_active_session"
    end
  end

  describe "GET /agents/:name/definition" do
    test "frontmatter covers every schema field (drift guard)" do
      # The endpoint hand-builds the frontmatter map, so a field added to
      # AgentDefinition.schema/0 but forgotten there would be silently
      # stripped from the definition file on the next builder save. This
      # test turns that drift into a failure.
      agents_dir = TriOnyx.agents_dir()
      File.mkdir_p!(agents_dir)
      file_path = Path.join(agents_dir, "drift-guard-agent.md")

      File.write!(file_path, """
      ---
      name: drift-guard-agent
      tools: Read
      ---

      Drift guard fixture.
      """)

      on_exit(fn -> File.rm(file_path) end)

      conn = conn(:get, "/agents/drift-guard-agent/definition") |> call_router()
      assert conn.status == 200

      frontmatter = Jason.decode!(conn.resp_body)["frontmatter"]

      schema_keys = Enum.map(AgentDefinition.schema().fields, & &1.key)
      missing = Enum.reject(schema_keys, &Map.has_key?(frontmatter, &1))

      assert missing == [],
             "schema fields missing from /agents/:name/definition frontmatter " <>
               "(builder saves would strip them): #{inspect(missing)}"
    end
  end

  describe "POST /agents name validation" do
    test "rejects a traversal name instead of writing outside the agents dir" do
      payload =
        Jason.encode!(%{
          "name" => "../../etc/pwned",
          "tools" => ["Read"],
          "system_prompt" => "nope"
        })

      conn =
        conn(:post, "/agents", payload)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "validation_failed"
      assert [%{"field" => "name"}] = body["details"]

      refute File.exists?(Path.join(TriOnyx.agents_dir(), "../../etc/pwned.md"))
    end
  end

  describe "GET /audio/:agent_name/:session_id/:audio_id" do
    test "rejects traversal in the agent name" do
      conn =
        conn(:get, "/audio/#{URI.encode("../../..", &(&1 != ?/))}/abc123/clip.ogg")
        |> call_router()

      assert conn.status == 400
    end

    test "rejects traversal in the session id" do
      conn =
        conn(:get, "/audio/test-agent/#{URI.encode("../../..", &(&1 != ?/))}/clip.ogg")
        |> call_router()

      assert conn.status == 400
    end

    test "accepts a well-formed path (404 when the file is absent)" do
      conn = conn(:get, "/audio/test-agent/abc123/clip.ogg") |> call_router()

      assert conn.status == 404
    end
  end

  describe "GET /images/:agent_name/:session_id/:image_id" do
    test "rejects traversal in the agent name" do
      conn =
        conn(:get, "/images/#{URI.encode("../../..", &(&1 != ?/))}/abc123/pic.png")
        |> call_router()

      assert conn.status == 400
    end

    test "rejects traversal in the session id" do
      conn =
        conn(:get, "/images/test-agent/#{URI.encode("../../..", &(&1 != ?/))}/pic.png")
        |> call_router()

      assert conn.status == 400
    end

    test "accepts a well-formed path (404 when the file is absent)" do
      conn = conn(:get, "/images/test-agent/abc123/pic.png") |> call_router()

      assert conn.status == 404
    end

    test "does not serve files outside the logs/ sandbox via agent_name traversal" do
      # Unlike /audio (which validates agent_name/session_id before building
      # the path — see the comment on that route), /images built its
      # safe_prefix straight from the unvalidated params. Since agent_name
      # and session_id are folded into safe_prefix itself, traversal there
      # relocates the "sandbox" along with the target and defeats the
      # containment check, letting an unauthenticated caller read any file
      # on the host whose parent directory they can name.
      secret_dir =
        Path.join(System.tmp_dir!(), "router_test_poc_#{System.unique_integer([:positive])}_images")

      File.mkdir_p!(secret_dir)
      secret_path = Path.join(secret_dir, "secret.txt")
      File.write!(secret_path, "top secret host file, outside logs/")
      on_exit(fn -> File.rm_rf!(secret_dir) end)

      parent = Path.dirname(secret_dir)
      session_id = Path.basename(secret_dir) |> String.replace_suffix("_images", "")
      # Enough ".." to reach "/" regardless of the test runner's cwd depth —
      # Path.expand caps at the root instead of erroring, so extras are inert.
      traversal = String.duplicate("../", 30) <> String.trim_leading(parent, "/")
      encoded_agent = URI.encode(traversal, &(&1 != ?/))

      conn =
        conn(:get, "/images/#{encoded_agent}/#{session_id}/secret.txt")
        |> call_router()

      refute conn.status == 200,
             "expected the traversal to be rejected, but the gateway served " <>
               "#{inspect(secret_path)} (status #{conn.status}, body: #{inspect(conn.resp_body)})"
    end
  end

  describe "catch-all" do
    test "returns 404 for unknown routes" do
      conn = conn(:get, "/unknown") |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end
end
