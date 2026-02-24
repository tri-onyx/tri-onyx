defmodule TriOnyx.ActionApprovalQueueTest do
  use ExUnit.Case, async: true

  alias TriOnyx.ActionApprovalQueue

  setup do
    {:ok, pid} = ActionApprovalQueue.start_link(name: :"test_aaq_#{:erlang.unique_integer()}")
    %{server: pid}
  end

  describe "submit/2" do
    test "returns {:ok, approval_id}", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{
        agent_name: "test-agent",
        session_id: "sess-1",
        tool_name: "SendEmail",
        tool_input: %{"draft_path" => "/workspace/draft.eml"}
      })

      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "submitted item appears in list_pending", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{
        agent_name: "test-agent",
        session_id: "sess-1",
        tool_name: "SendEmail",
        tool_input: %{}
      })

      pending = ActionApprovalQueue.list_pending(server)
      assert length(pending) == 1
      assert hd(pending).id == id
      assert hd(pending).tool_name == "SendEmail"
    end
  end

  describe "approve/2" do
    test "approves a pending item", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{agent_name: "a", tool_name: "SendEmail"})
      {:ok, item} = ActionApprovalQueue.approve(server, id)
      assert item.id == id
      assert ActionApprovalQueue.list_pending(server) == []
    end

    test "returns {:error, :not_found} for unknown id", %{server: server} do
      assert {:error, :not_found} = ActionApprovalQueue.approve(server, "nonexistent")
    end
  end

  describe "reject/3" do
    test "rejects a pending item with reason", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{agent_name: "a", tool_name: "SendEmail"})
      {:ok, item} = ActionApprovalQueue.reject(server, id, "not allowed")
      assert item.id == id
      assert ActionApprovalQueue.list_pending(server) == []
    end

    test "returns {:error, :not_found} for unknown id", %{server: server} do
      assert {:error, :not_found} = ActionApprovalQueue.reject(server, "nonexistent", "reason")
    end
  end

  describe "await_decision/3" do
    test "returns immediately if already approved", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{agent_name: "a", tool_name: "SendEmail"})
      ActionApprovalQueue.approve(server, id)
      assert {:approved, item} = ActionApprovalQueue.await_decision(server, id)
      assert item.id == id
    end

    test "returns immediately if already rejected", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{agent_name: "a", tool_name: "SendEmail"})
      ActionApprovalQueue.reject(server, id, "nope")
      assert {:rejected, "nope"} = ActionApprovalQueue.await_decision(server, id)
    end

    test "blocks until approved", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{agent_name: "a", tool_name: "SendEmail"})

      task = Task.async(fn ->
        ActionApprovalQueue.await_decision(server, id, 5_000)
      end)

      # Small delay to ensure the task is waiting
      Process.sleep(50)
      ActionApprovalQueue.approve(server, id)

      assert {:approved, item} = Task.await(task)
      assert item.id == id
    end

    test "blocks until rejected", %{server: server} do
      {:ok, id} = ActionApprovalQueue.submit(server, %{agent_name: "a", tool_name: "SendEmail"})

      task = Task.async(fn ->
        ActionApprovalQueue.await_decision(server, id, 5_000)
      end)

      Process.sleep(50)
      ActionApprovalQueue.reject(server, id, "denied")

      assert {:rejected, "denied"} = Task.await(task)
    end

    test "returns {:error, :not_found} for unknown id", %{server: server} do
      assert {:error, :not_found} = ActionApprovalQueue.await_decision(server, "nonexistent")
    end
  end

  describe "list_pending/1" do
    test "returns empty list initially", %{server: server} do
      assert ActionApprovalQueue.list_pending(server) == []
    end

    test "returns multiple pending items", %{server: server} do
      ActionApprovalQueue.submit(server, %{agent_name: "a", tool_name: "SendEmail"})
      ActionApprovalQueue.submit(server, %{agent_name: "b", tool_name: "SendEmail"})
      assert length(ActionApprovalQueue.list_pending(server)) == 2
    end
  end
end
