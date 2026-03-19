defmodule TriOnyx.ActionApprovalViaUnifiedQueueTest do
  @moduledoc """
  Tests that action approvals (kind: \"action\") work through the unified
  BCP.ApprovalQueue, which now handles both BCP and action approvals.
  """
  use ExUnit.Case, async: true

  alias TriOnyx.BCP.ApprovalQueue

  setup do
    {:ok, pid} = ApprovalQueue.start_link(name: :"test_aaq_#{:erlang.unique_integer()}")
    %{server: pid}
  end

  describe "action approval submit/2" do
    test "returns {:ok, approval_id}", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{
        kind: "action",
        agent_name: "test-agent",
        session_id: "sess-1",
        tool_name: "SendEmail",
        tool_input: %{"draft_path" => "/workspace/draft.eml"}
      })

      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "submitted item appears in list_pending with kind", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{
        kind: "action",
        agent_name: "test-agent",
        session_id: "sess-1",
        tool_name: "SendEmail",
        tool_input: %{}
      })

      pending = ApprovalQueue.list_pending(server)
      assert length(pending) == 1
      assert hd(pending).id == id
      assert hd(pending).kind == "action"
      assert hd(pending).tool_name == "SendEmail"
    end
  end

  describe "action approval approve/2" do
    test "approves a pending action item", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{kind: "action", agent_name: "a", tool_name: "SendEmail"})
      {:ok, item} = ApprovalQueue.approve(server, id)
      assert item.id == id
      assert ApprovalQueue.list_pending(server) == []
    end

    test "returns {:error, :not_found} for unknown id", %{server: server} do
      assert {:error, :not_found} = ApprovalQueue.approve(server, "nonexistent")
    end
  end

  describe "action approval reject/3" do
    test "rejects a pending action item with reason", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{kind: "action", agent_name: "a", tool_name: "SendEmail"})
      {:ok, item} = ApprovalQueue.reject(server, id, "not allowed")
      assert item.id == id
      assert ApprovalQueue.list_pending(server) == []
    end

    test "returns {:error, :not_found} for unknown id", %{server: server} do
      assert {:error, :not_found} = ApprovalQueue.reject(server, "nonexistent", "reason")
    end
  end

  describe "action approval await_decision/3" do
    test "returns immediately if already approved", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{kind: "action", agent_name: "a", tool_name: "SendEmail"})
      ApprovalQueue.approve(server, id)
      assert {:approved, item} = ApprovalQueue.await_decision(server, id)
      assert item.id == id
    end

    test "returns immediately if already rejected", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{kind: "action", agent_name: "a", tool_name: "SendEmail"})
      ApprovalQueue.reject(server, id, "nope")
      assert {:rejected, "nope"} = ApprovalQueue.await_decision(server, id)
    end

    test "blocks until approved", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{kind: "action", agent_name: "a", tool_name: "SendEmail"})

      task = Task.async(fn ->
        ApprovalQueue.await_decision(server, id, 5_000)
      end)

      Process.sleep(50)
      ApprovalQueue.approve(server, id)

      assert {:approved, item} = Task.await(task)
      assert item.id == id
    end

    test "blocks until rejected", %{server: server} do
      {:ok, id} = ApprovalQueue.submit(server, %{kind: "action", agent_name: "a", tool_name: "SendEmail"})

      task = Task.async(fn ->
        ApprovalQueue.await_decision(server, id, 5_000)
      end)

      Process.sleep(50)
      ApprovalQueue.reject(server, id, "denied")

      assert {:rejected, "denied"} = Task.await(task)
    end

    test "returns {:error, :not_found} for unknown id", %{server: server} do
      assert {:error, :not_found} = ApprovalQueue.await_decision(server, "nonexistent")
    end
  end

  describe "mixed bcp and action items" do
    test "both kinds coexist in the same queue", %{server: server} do
      {:ok, bcp_id} = ApprovalQueue.submit(server, %{
        kind: "bcp",
        from_agent: "agent-a",
        to_agent: "agent-b"
      })

      {:ok, action_id} = ApprovalQueue.submit(server, %{
        kind: "action",
        agent_name: "email",
        tool_name: "SendEmail"
      })

      pending = ApprovalQueue.list_pending(server)
      assert length(pending) == 2

      kinds = Enum.map(pending, & &1.kind) |> Enum.sort()
      assert kinds == ["action", "bcp"]

      # Approve only the action
      ApprovalQueue.approve(server, action_id)
      remaining = ApprovalQueue.list_pending(server)
      assert length(remaining) == 1
      assert hd(remaining).id == bcp_id
    end
  end
end
