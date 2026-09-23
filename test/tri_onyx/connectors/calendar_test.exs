defmodule TriOnyx.Connectors.CalendarTest do
  use ExUnit.Case, async: true

  alias TriOnyx.Connectors.Calendar

  @tmp_dir "tmp/test-calendar-#{:erlang.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    %{tmp_dir: @tmp_dir}
  end

  describe "calendar_delete/3 — calendar name containment" do
    # Security property: `calendar_delete/3` builds
    # `{workspace_agent_dir}/events/{calendar}/{uid}.json` and reads it
    # before ever touching the network. `calendar` comes straight from the
    # CalendarDelete tool call (agent-controlled) and, unlike
    # `TriOnyx.Connectors.Email.validate_folder_name/1` for email folder
    # names, was never checked for path-traversal components — so a `../`
    # in `calendar` lets an agent read (and, once CalDAV accepts the
    # forged delete, remove) an arbitrary cached-event file outside its own
    # workspace tree, breaking the "mount set is the ACL" boundary
    # (AGENTS.md, "Per-Agent Repos").
    test "does not read a cached-event file outside workspace_agent_dir/events/ via a traversing calendar name",
         %{tmp_dir: tmp_dir} do
      workspace_agent_dir = Path.join(tmp_dir, "agent")
      secret_dir = Path.join(tmp_dir, "secret")
      File.mkdir_p!(secret_dir)
      # A real agent's workspace already has this directory (calendar_query/2
      # creates it on the first query) — the OS resolves ".." by walking the
      # real directory tree, so the traversal needs this to actually exist,
      # just as it would in the workspace of any agent that has ever run a
      # calendar query.
      File.mkdir_p!(Path.join(workspace_agent_dir, "events"))

      # Valid JSON but missing "href" — its presence in the response proves
      # this exact file was read and decoded (a "not found" or "not
      # configured" error would not distinguish that from the traversal
      # simply failing).
      File.write!(Path.join(secret_dir, "poc123.json"), Jason.encode!(%{"foo" => "bar"}))

      result = Calendar.calendar_delete("poc123", "../../secret", workspace_agent_dir)

      refute result == {:error, "missing href in event"},
             "calendar_delete/3 read and parsed #{inspect(Path.join(secret_dir, "poc123.json"))}, " <>
               "a file outside #{inspect(workspace_agent_dir)}, via a traversing \"calendar\" " <>
               "parameter — got #{inspect(result)}"

      assert {:error, "invalid calendar name: " <> _} = result
    end

    test "still resolves an ordinary calendar name (no false rejection)" do
      workspace_agent_dir = Path.join(@tmp_dir, "agent2")

      assert {:error, "event file not found: " <> _} =
               Calendar.calendar_delete("poc123", "personal", workspace_agent_dir)
    end
  end

  describe "calendar_query/2 — calendar name containment" do
    test "rejects a traversing calendar name before touching the network" do
      workspace_agent_dir = Path.join(@tmp_dir, "agent3")

      assert {:error, "invalid calendar name: " <> _} =
               Calendar.calendar_query(workspace_agent_dir, %{"calendar" => "../../etc"})
    end

    test "still resolves an ordinary calendar name (no false rejection)" do
      workspace_agent_dir = Path.join(@tmp_dir, "agent4")

      assert {:error, "calendar not configured" <> _} =
               Calendar.calendar_query(workspace_agent_dir, %{"calendar" => "work"})
    end
  end
end
