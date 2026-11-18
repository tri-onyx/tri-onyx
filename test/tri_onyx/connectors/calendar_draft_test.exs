defmodule TriOnyx.Connectors.CalendarDraftTest do
  # Mutates the global :calendar application env, so not async.
  use ExUnit.Case, async: false

  alias TriOnyx.Connectors.Calendar

  @tmp_dir "tmp/test-calendar-draft-#{:erlang.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@tmp_dir)
    previous = Application.get_env(:tri_onyx, :calendar)

    {port, server} = start_fake_caldav()

    Application.put_env(:tri_onyx, :calendar,
      caldav: %{
        url: "http://127.0.0.1:#{port}",
        username: "user",
        password: "pass",
        calendar_base_path: "/caldav"
      }
    )

    on_exit(fn ->
      Process.exit(server, :kill)
      File.rm_rf!(@tmp_dir)

      if previous,
        do: Application.put_env(:tri_onyx, :calendar, previous),
        else: Application.delete_env(:tri_onyx, :calendar)
    end)

    %{tmp_dir: @tmp_dir}
  end

  # Loopback-only stand-in for a CalDAV server: answers every request with
  # 201 Created and reports the raw request line back to the test process.
  defp start_fake_caldav do
    test_pid = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        accept_loop(listen, test_pid)
      end)

    :ok = :gen_tcp.controlling_process(listen, server)
    {port, server}
  end

  defp accept_loop(listen, test_pid) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        send(test_pid, {:caldav_request, data})
        :gen_tcp.send(sock, "HTTP/1.1 201 Created\r\nETag: \"e1\"\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(sock)
        accept_loop(listen, test_pid)

      {:error, _} ->
        :ok
    end
  end

  defp write_draft(tmp_dir, name, draft) do
    path = Path.join(tmp_dir, name)
    File.write!(path, Jason.encode!(draft))
    path
  end

  describe "calendar_create/1 — draft calendar name containment" do
    # Security property: the `calendar` field of a CalendarCreate draft is
    # agent-authored (the draft lives in the agent's own /workspace). On
    # success, AgentSession.write_calendar_event/2 does
    # `File.mkdir_p!(Path.join([agent_dir, "events", event["calendar"]]))`
    # and writes the event JSON there, so a `../` calendar name lets a
    # sandboxed agent create directories and plant files in another agent's
    # (or a shared repo's) working tree — outside its mount set, which
    # AGENTS.md says is the ACL. The same unescaped value is also spliced
    # into the raw CalDAV request line (`href`), so a CR/LF in it injects
    # headers or extra requests on the credentialed connection.
    test "rejects a traversing calendar name before the event is created", %{tmp_dir: tmp_dir} do
      draft =
        write_draft(tmp_dir, "create.json", %{
          "calendar" => "../../../victim/self/events/personal",
          "summary" => "s",
          "dtstart" => "2026-01-01T10:00:00Z",
          "dtend" => "2026-01-01T11:00:00Z"
        })

      result = Calendar.calendar_create(draft)

      refute match?({:ok, _}, result),
             "calendar_create/1 accepted calendar \"../../../victim/self/events/personal\" and returned " <>
               "#{inspect(result)} — AgentSession.write_calendar_event/2 would then write the event " <>
               "file outside the agent's own tree"

      assert {:error, "invalid calendar name: " <> _} = result
      refute_received {:caldav_request, _}, "a request reached the CalDAV server for an invalid calendar"
    end

    test "rejects a calendar name carrying CRLF (request-line injection)", %{tmp_dir: tmp_dir} do
      draft =
        write_draft(tmp_dir, "create-crlf.json", %{
          "calendar" => "personal\r\nX-Injected: 1",
          "summary" => "s",
          "dtstart" => "2026-01-01T10:00:00Z",
          "dtend" => "2026-01-01T11:00:00Z"
        })

      assert {:error, "invalid calendar name: " <> _} = Calendar.calendar_create(draft)
      refute_received {:caldav_request, _}
    end

    test "still creates events in an ordinary calendar", %{tmp_dir: tmp_dir} do
      draft =
        write_draft(tmp_dir, "create-ok.json", %{
          "calendar" => "personal",
          "summary" => "s",
          "dtstart" => "2026-01-01T10:00:00Z",
          "dtend" => "2026-01-01T11:00:00Z"
        })

      assert {:ok, %{"calendar" => "personal", "href" => "/caldav/personal/" <> _}} =
               Calendar.calendar_create(draft)

      assert_received {:caldav_request, "PUT /caldav/personal/" <> _}
    end
  end

  describe "calendar_update/1 — draft calendar name containment" do
    test "rejects a traversing calendar name in an update draft", %{tmp_dir: tmp_dir} do
      draft =
        write_draft(tmp_dir, "update.json", %{
          "uid" => "abc@tri-onyx",
          "etag" => "\"e0\"",
          "href" => "/caldav/personal/abc@tri-onyx.ics",
          "calendar" => "../../../victim/self/events/personal"
        })

      result = Calendar.calendar_update(draft)

      refute match?({:ok, _}, result),
             "calendar_update/1 accepted calendar \"../../../victim/self/events/personal\" and returned " <>
               "#{inspect(result)} — AgentSession.write_calendar_event/2 would then write outside " <>
               "the agent's own tree"

      assert {:error, "invalid calendar name: " <> _} = result
      refute_received {:caldav_request, _}
    end

    test "still accepts an update draft with an ordinary or omitted calendar", %{tmp_dir: tmp_dir} do
      base = %{
        "uid" => "abc@tri-onyx",
        "etag" => "\"e0\"",
        "href" => "/caldav/personal/abc@tri-onyx.ics"
      }

      with_cal = write_draft(tmp_dir, "update-ok.json", Map.put(base, "calendar", "personal"))
      assert {:ok, %{"calendar" => "personal"}} = Calendar.calendar_update(with_cal)

      without_cal = write_draft(tmp_dir, "update-nocal.json", base)
      assert {:ok, %{"calendar" => ""}} = Calendar.calendar_update(without_cal)
    end
  end
end
