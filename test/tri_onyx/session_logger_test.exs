defmodule TriOnyx.SessionLoggerTest do
  # Not async: mutates the global :session_log_dir application env.
  use ExUnit.Case, async: false

  alias TriOnyx.SessionLogger

  setup do
    unique = :erlang.unique_integer([:positive])
    root = Path.expand("./tmp/session-logger-test-#{unique}")
    log_dir = Path.join(root, "logs")

    File.mkdir_p!(Path.join(log_dir, "main"))
    File.write!(Path.join([log_dir, "main", "sess-1.jsonl"]), ~s({"event":"ok"}\n))

    # A file OUTSIDE the log base dir that a traversal would reach
    File.write!(Path.join(root, "secret.jsonl"), "TOP SECRET\n")

    previous = Application.get_env(:tri_onyx, :session_log_dir)
    Application.put_env(:tri_onyx, :session_log_dir, log_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:tri_onyx, :session_log_dir, previous)
      else
        Application.delete_env(:tri_onyx, :session_log_dir)
      end

      File.rm_rf!(root)
    end)

    %{root: root, log_dir: log_dir}
  end

  describe "list_sessions/1" do
    test "lists sessions for a valid agent" do
      assert [%{"session_id" => "sess-1"}] = SessionLogger.list_sessions("main")
    end

    test "returns empty list for unknown agent" do
      assert SessionLogger.list_sessions("nonexistent") == []
    end

    test "rejects path traversal in agent name", %{root: root} do
      # "logs/.." resolves to the root dir which contains secret.jsonl —
      # a traversal would list it as a session
      assert SessionLogger.list_sessions("..") == []
      assert SessionLogger.list_sessions("../..") == []
      assert SessionLogger.list_sessions("foo/../..") == []
      # Sanity: the decoy really is where a traversal would find it
      assert File.exists?(Path.join(root, "secret.jsonl"))
    end
  end

  describe "read_session/2" do
    test "reads an existing session log" do
      assert {:ok, content} = SessionLogger.read_session("main", "sess-1")
      assert content =~ "event"
    end

    test "returns not_found for missing session" do
      assert {:error, :not_found} = SessionLogger.read_session("main", "nope")
    end

    test "rejects path traversal in agent name" do
      # Would resolve to <root>/secret.jsonl without the containment check
      assert {:error, :not_found} = SessionLogger.read_session("..", "secret")
    end

    test "rejects path traversal in session id" do
      assert {:error, :not_found} = SessionLogger.read_session("main", "../../secret")
      # Escaping into a sibling agent's directory is also rejected
      assert {:error, :not_found} = SessionLogger.read_session("other", "../main/sess-1")
    end

    test "rejects absolute-path session id", %{root: root} do
      assert {:error, :not_found} =
               SessionLogger.read_session("main", Path.join(root, "secret"))
    end
  end
end
