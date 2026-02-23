defmodule TriOnyx.Connectors.Calendar do
  @moduledoc """
  CalDAV connector for TriOnyx agents.

  Provides CalDAV operations: querying events, creating, updating, and deleting.
  Credentials are held by the gateway — agents never see them.

  ## Public API

  - `calendar_query/2` — CalDAV REPORT for a date range, writes event JSON files
  - `calendar_create/1` — reads a draft JSON file, generates iCal, CalDAV PUT
  - `calendar_update/1` — reads an update-draft, conditional PUT (If-Match)
  - `calendar_delete/3` — looks up href+etag from cache, CalDAV DELETE
  """

  require Logger

  @doc """
  Queries a calendar for events within a date range.

  Sends a CalDAV REPORT, parses iCal responses, writes event JSON files
  to the agent's workspace, and returns the list of events.

  Returns `{:ok, events}` on success where events is a list of maps.
  """
  @spec calendar_query(String.t(), map()) :: {:ok, [map()]} | {:error, String.t()}
  def calendar_query(workspace_agent_dir, params) do
    calendar = Map.get(params, "calendar", "personal")
    from = Map.get(params, "from")
    to = Map.get(params, "to")

    with {:ok, config} <- get_caldav_config(),
         {:ok, ical_data} <- caldav_report(config, calendar, from, to),
         {:ok, events} <- parse_icalendar_multi(ical_data) do
      # Write event JSON files
      events_dir = Path.join([workspace_agent_dir, "events", calendar])
      File.mkdir_p!(events_dir)

      written_events =
        Enum.map(events, fn event ->
          event = Map.put(event, "calendar", calendar)
          uid = event["uid"] || "unknown"
          safe_uid = sanitize_uid(uid)
          path = Path.join(events_dir, "#{safe_uid}.json")
          File.write!(path, Jason.encode!(event, pretty: true))
          event
        end)

      Logger.info("CalendarQuery: #{length(written_events)} events written for calendar=#{calendar}")
      {:ok, written_events}
    end
  end

  @doc """
  Creates a new calendar event from a draft JSON file.

  The draft must contain `calendar`, `summary`, `dtstart`, and `dtend`.
  Optional: `description`, `location`, `attendees`.

  Returns `{:ok, event}` on success with the created event map.
  """
  @spec calendar_create(String.t()) :: {:ok, map()} | {:error, String.t()}
  def calendar_create(host_draft_path) do
    with {:ok, contents} <- read_draft(host_draft_path),
         {:ok, draft} <- parse_create_draft(contents),
         {:ok, config} <- get_caldav_config() do
      uid = generate_uid()
      ical = generate_icalendar(Map.put(draft, "uid", uid))
      calendar = draft["calendar"]
      href = "#{config.calendar_base_path}/#{calendar}/#{uid}.ics"

      case caldav_put(config, href, ical, nil) do
        {:ok, etag} ->
          event = %{
            "uid" => uid,
            "summary" => draft["summary"],
            "description" => Map.get(draft, "description", ""),
            "location" => Map.get(draft, "location", ""),
            "dtstart" => draft["dtstart"],
            "dtend" => draft["dtend"],
            "organizer" => config.username,
            "attendees" => Map.get(draft, "attendees", []),
            "status" => "CONFIRMED",
            "recurrence" => nil,
            "calendar" => calendar,
            "etag" => etag,
            "href" => href
          }

          Logger.info("CalendarCreate: event #{uid} created in #{calendar}")
          {:ok, event}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Updates an existing calendar event from an update-draft JSON file.

  The draft must include `uid`, `etag`, and `href` for conflict detection.
  Uses conditional PUT with If-Match header.

  Returns `{:ok, event}` on success with the updated event map.
  """
  @spec calendar_update(String.t()) :: {:ok, map()} | {:error, String.t()}
  def calendar_update(host_draft_path) do
    with {:ok, contents} <- read_draft(host_draft_path),
         {:ok, draft} <- parse_update_draft(contents),
         {:ok, config} <- get_caldav_config() do
      ical = generate_icalendar(draft)
      href = draft["href"]
      etag = draft["etag"]

      case caldav_put(config, href, ical, etag) do
        {:ok, new_etag} ->
          event = %{
            "uid" => draft["uid"],
            "summary" => Map.get(draft, "summary", ""),
            "description" => Map.get(draft, "description", ""),
            "location" => Map.get(draft, "location", ""),
            "dtstart" => Map.get(draft, "dtstart", ""),
            "dtend" => Map.get(draft, "dtend", ""),
            "organizer" => config.username,
            "attendees" => Map.get(draft, "attendees", []),
            "status" => Map.get(draft, "status", "CONFIRMED"),
            "recurrence" => Map.get(draft, "recurrence"),
            "calendar" => Map.get(draft, "calendar", ""),
            "etag" => new_etag,
            "href" => href
          }

          Logger.info("CalendarUpdate: event #{draft["uid"]} updated")
          {:ok, event}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes a calendar event by UID and calendar name.

  Looks up the href and etag from the cached event file, then sends
  a CalDAV DELETE request.

  Returns `{:ok, :deleted}` on success.
  """
  @spec calendar_delete(String.t(), String.t(), String.t()) ::
          {:ok, :deleted} | {:error, String.t()}
  def calendar_delete(uid, calendar, workspace_agent_dir) do
    events_dir = Path.join([workspace_agent_dir, "events", calendar])
    safe_uid = sanitize_uid(uid)
    event_path = Path.join(events_dir, "#{safe_uid}.json")

    with {:ok, contents} <- File.read(event_path),
         {:ok, event} <- Jason.decode(contents),
         href when is_binary(href) <- Map.get(event, "href") || {:error, "missing href in event"},
         etag when is_binary(etag) <- Map.get(event, "etag") || {:error, "missing etag in event"},
         {:ok, config} <- get_caldav_config(),
         :ok <- caldav_delete(config, href, etag) do
      # Remove cached event file
      File.rm(event_path)
      Logger.info("CalendarDelete: event #{uid} deleted from #{calendar}")
      {:ok, :deleted}
    else
      {:error, :enoent} -> {:error, "event file not found: #{event_path}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "calendar delete failed: #{inspect(reason)}"}
    end
  end

  # --- CalDAV HTTP Helpers ---

  @spec get_caldav_config() :: {:ok, map()} | {:error, String.t()}
  defp get_caldav_config do
    case Application.get_env(:tri_onyx, :calendar) do
      nil -> {:error, "calendar not configured (TRI_ONYX_CALDAV_URL not set)"}
      config -> {:ok, config[:caldav]}
    end
  end

  @spec caldav_report(map(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp caldav_report(config, calendar, from, to) do
    path = "#{config.calendar_base_path}/#{calendar}/"

    # Build CalDAV REPORT XML body
    time_range =
      cond do
        from && to ->
          ~s(<C:time-range start="#{to_ical_utc(from)}" end="#{to_ical_utc(to)}"/>)

        from ->
          ~s(<C:time-range start="#{to_ical_utc(from)}"/>)

        to ->
          ~s(<C:time-range end="#{to_ical_utc(to)}"/>)

        true ->
          ""
      end

    body = """
    <?xml version="1.0" encoding="utf-8" ?>
    <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop>
        <D:getetag/>
        <C:calendar-data/>
      </D:prop>
      <C:filter>
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            #{time_range}
          </C:comp-filter>
        </C:comp-filter>
      </C:filter>
    </C:calendar-query>
    """

    caldav_request(config, "REPORT", path, body, [
      {"Depth", "1"},
      {"Content-Type", "application/xml; charset=utf-8"}
    ])
  end

  @spec caldav_put(map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp caldav_put(config, href, ical_body, etag) do
    headers = [{"Content-Type", "text/calendar; charset=utf-8"}]

    headers =
      if etag do
        [{"If-Match", etag} | headers]
      else
        [{"If-None-Match", "*"} | headers]
      end

    case caldav_request(config, "PUT", href, ical_body, headers) do
      {:ok, response_body} ->
        # Extract ETag from response (or generate placeholder)
        new_etag =
          case Regex.run(~r/ETag:\s*"?([^"\r\n]+)"?/i, response_body) do
            [_, etag_val] -> "\"#{etag_val}\""
            _ -> "\"#{:crypto.hash(:md5, ical_body) |> Base.encode16(case: :lower)}\""
          end

        {:ok, new_etag}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec caldav_delete(map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  defp caldav_delete(config, href, etag) do
    headers = [{"If-Match", etag}]

    case caldav_request(config, "DELETE", href, "", headers) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # CalDAV uses non-standard HTTP methods (REPORT, PROPFIND) that Erlang's
  # :httpc does not support. We use raw :ssl/:gen_tcp sockets instead.
  @spec caldav_request(map(), String.t(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp caldav_request(config, method, path, body, extra_headers) do
    uri = URI.parse(config.url)
    host = uri.host
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
    ssl? = uri.scheme == "https"

    auth = Base.encode64("#{config.username}:#{config.password}")

    headers =
      [
        {"Host", host},
        {"Authorization", "Basic #{auth}"},
        {"User-Agent", "TriOnyx/1.0"},
        {"Connection", "close"}
      ] ++ extra_headers

    headers =
      if body != "" do
        headers ++ [{"Content-Length", Integer.to_string(byte_size(body))}]
      else
        headers
      end

    header_str = Enum.map_join(headers, "\r\n", fn {k, v} -> "#{k}: #{v}" end)
    request = "#{method} #{path} HTTP/1.1\r\n#{header_str}\r\n\r\n#{body}"

    try do
      {socket, transport} = connect_socket(host, port, ssl?)

      case send_data(socket, transport, request) do
        :ok ->
          case recv_full_response(socket, transport, "") do
            {:ok, raw_response} ->
              transport_close(socket, transport)
              parse_http_response(raw_response, method)

            {:error, reason} ->
              transport_close(socket, transport)
              {:error, "CalDAV recv failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          transport_close(socket, transport)
          {:error, "CalDAV send failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "CalDAV connection failed: #{Exception.message(e)}"}
    catch
      {:error, _} = err -> err
    end
  end

  defp connect_socket(host, port, true) do
    ssl_opts = [
      {:active, false},
      :binary,
      {:server_name_indication, String.to_charlist(host)},
      {:verify, :verify_none}
    ]

    {:ok, socket} = :ssl.connect(String.to_charlist(host), port, ssl_opts, 15_000)
    {socket, :ssl}
  end

  defp connect_socket(host, port, false) do
    {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [{:active, false}, :binary], 15_000)
    {socket, :gen_tcp}
  end

  defp send_data(socket, :ssl, data), do: :ssl.send(socket, data)
  defp send_data(socket, :gen_tcp, data), do: :gen_tcp.send(socket, data)

  defp recv_full_response(socket, transport, acc) do
    case recv_data(socket, transport) do
      {:ok, data} ->
        recv_full_response(socket, transport, acc <> data)

      {:error, :closed} ->
        {:ok, acc}

      {:error, reason} ->
        if acc != "" do
          {:ok, acc}
        else
          {:error, reason}
        end
    end
  end

  defp recv_data(socket, :ssl), do: :ssl.recv(socket, 0, 30_000)
  defp recv_data(socket, :gen_tcp), do: :gen_tcp.recv(socket, 0, 30_000)

  defp transport_close(socket, :ssl), do: :ssl.close(socket)
  defp transport_close(socket, :gen_tcp), do: :gen_tcp.close(socket)

  defp parse_http_response(raw, method) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [header_section, body] ->
        case Regex.run(~r/^HTTP\/1\.[01] (\d+)/, header_section) do
          [_, status_str] ->
            status = String.to_integer(status_str)

            cond do
              status in 200..299 or status == 207 ->
                {:ok, header_section <> "\r\n\r\n" <> body}

              status == 412 ->
                {:error, "precondition failed (event was modified on server — etag mismatch)"}

              true ->
                {:error, "CalDAV #{method} failed: HTTP #{status} — #{String.slice(body, 0, 500)}"}
            end

          _ ->
            {:error, "CalDAV: malformed HTTP response"}
        end

      _ ->
        {:error, "CalDAV: incomplete HTTP response"}
    end
  end

  # --- iCalendar Parsing ---

  @doc """
  Parses a CalDAV multistatus response containing multiple VCALENDAR objects
  into a list of event maps.
  """
  @spec parse_icalendar_multi(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def parse_icalendar_multi(response_body) do
    try do
      # Extract calendar-data elements from the multistatus XML response
      ical_blocks =
        Regex.scan(~r/<C:calendar-data[^>]*>(.*?)<\/C:calendar-data>/s, response_body)
        |> Enum.map(fn [_, ical_data] -> unescape_xml(ical_data) end)

      # If no XML wrapper, try parsing the whole body as iCal
      ical_blocks =
        if ical_blocks == [] and String.contains?(response_body, "BEGIN:VCALENDAR") do
          [response_body]
        else
          ical_blocks
        end

      events =
        Enum.flat_map(ical_blocks, fn block ->
          case parse_icalendar(block) do
            {:ok, event_list} -> event_list
            _ -> []
          end
        end)

      # Extract etags and hrefs from the multistatus response
      events = enrich_with_multistatus(events, response_body)

      {:ok, events}
    rescue
      e -> {:error, "iCal parsing failed: #{Exception.message(e)}"}
    end
  end

  @spec parse_icalendar(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  defp parse_icalendar(ical_text) do
    # Split into VEVENT blocks
    vevent_blocks = Regex.scan(~r/BEGIN:VEVENT(.*?)END:VEVENT/s, ical_text)

    events =
      Enum.map(vevent_blocks, fn [_, block] ->
        %{
          "uid" => extract_ical_prop(block, "UID"),
          "summary" => extract_ical_prop(block, "SUMMARY"),
          "description" => extract_ical_prop(block, "DESCRIPTION"),
          "location" => extract_ical_prop(block, "LOCATION"),
          "dtstart" => extract_ical_datetime(block, "DTSTART"),
          "dtend" => extract_ical_datetime(block, "DTEND"),
          "organizer" => extract_ical_organizer(block),
          "attendees" => extract_ical_attendees(block),
          "status" => extract_ical_prop(block, "STATUS") || "CONFIRMED",
          "recurrence" => extract_ical_prop(block, "RRULE")
        }
      end)

    {:ok, events}
  end

  defp extract_ical_prop(block, prop_name) do
    case Regex.run(~r/^#{prop_name}[;:]([^\r\n]*)/m, block) do
      [_, value] -> String.trim(unfold_ical(value))
      _ -> nil
    end
  end

  defp extract_ical_datetime(block, prop_name) do
    case Regex.run(~r/^#{prop_name}[^:\r\n]*:([^\r\n]*)/m, block) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp extract_ical_organizer(block) do
    case Regex.run(~r/^ORGANIZER[^:]*:mailto:([^\r\n]*)/mi, block) do
      [_, email] -> String.trim(email)
      _ ->
        case Regex.run(~r/^ORGANIZER[;:]([^\r\n]*)/m, block) do
          [_, value] -> String.trim(value)
          _ -> nil
        end
    end
  end

  defp extract_ical_attendees(block) do
    Regex.scan(~r/^ATTENDEE[^:]*:mailto:([^\r\n]*)/mi, block)
    |> Enum.map(fn [_, email] -> String.trim(email) end)
  end

  defp unfold_ical(text) do
    # iCal line unfolding: lines starting with space/tab are continuations
    String.replace(text, ~r/\r?\n[ \t]/, "")
  end

  defp unescape_xml(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
  end

  # Enrich events with etag and href from the multistatus XML response
  defp enrich_with_multistatus(events, response_body) do
    # Parse href→etag mappings from multistatus
    responses =
      Regex.scan(~r/<D:response>(.*?)<\/D:response>/s, response_body)
      |> Enum.reduce(%{}, fn [_, resp_block], acc ->
        href =
          case Regex.run(~r/<D:href>([^<]+)<\/D:href>/, resp_block) do
            [_, h] -> String.trim(h)
            _ -> nil
          end

        etag =
          case Regex.run(~r/<D:getetag>"?([^"<]+)"?<\/D:getetag>/, resp_block) do
            [_, e] -> "\"#{String.trim(e)}\""
            _ -> nil
          end

        if href, do: Map.put(acc, href, etag), else: acc
      end)

    # Match events to their href by checking which href contains the UID
    Enum.map(events, fn event ->
      uid = event["uid"]

      {matched_href, matched_etag} =
        Enum.find(responses, {nil, nil}, fn {href, _etag} ->
          uid && String.contains?(href, sanitize_uid(uid))
        end)

      event
      |> Map.put("etag", matched_etag || Map.get(event, "etag"))
      |> Map.put("href", matched_href || Map.get(event, "href"))
    end)
  end

  # --- iCalendar Generation ---

  @doc """
  Generates an iCalendar string from an event map.
  """
  @spec generate_icalendar(map()) :: String.t()
  def generate_icalendar(event) do
    uid = event["uid"]
    now = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

    attendee_lines =
      (event["attendees"] || [])
      |> Enum.map_join("\r\n", fn email -> "ATTENDEE;RSVP=TRUE:mailto:#{email}" end)

    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//TriOnyx//CalDAV Client//EN",
        "BEGIN:VEVENT",
        "UID:#{uid}",
        "DTSTAMP:#{now}",
        "DTSTART:#{format_ical_datetime(event["dtstart"])}",
        "DTEND:#{format_ical_datetime(event["dtend"])}",
        if(event["summary"], do: "SUMMARY:#{escape_ical(event["summary"])}"),
        if(event["description"], do: "DESCRIPTION:#{escape_ical(event["description"])}"),
        if(event["location"], do: "LOCATION:#{escape_ical(event["location"])}"),
        if(event["status"], do: "STATUS:#{event["status"]}"),
        if(event["recurrence"], do: "RRULE:#{event["recurrence"]}"),
        if(attendee_lines != "", do: attendee_lines),
        "END:VEVENT",
        "END:VCALENDAR"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(lines, "\r\n") <> "\r\n"
  end

  defp format_ical_datetime(datetime) when is_binary(datetime) do
    # If already in iCal format (YYYYMMDDTHHMMSSZ), return as-is
    if Regex.match?(~r/^\d{8}T\d{6}/, datetime) do
      datetime
    else
      # Try to parse ISO 8601 and convert to iCal format
      case DateTime.from_iso8601(datetime) do
        {:ok, dt, _offset} ->
          Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")

        _ ->
          # Return as-is if parsing fails
          datetime
      end
    end
  end

  defp format_ical_datetime(nil), do: ""

  defp escape_ical(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp escape_ical(nil), do: ""

  defp to_ical_utc(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _offset} ->
        Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")

      _ ->
        # If already in iCal format or unparseable, return as-is
        datetime_str
    end
  end

  # --- Draft Validation ---

  @spec read_draft(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_draft(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "cannot read draft: #{inspect(reason)}"}
    end
  end

  @spec parse_create_draft(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp parse_create_draft(contents) do
    case Jason.decode(contents) do
      {:ok, draft} ->
        with :ok <- validate_field(draft, "calendar"),
             :ok <- validate_field(draft, "summary"),
             :ok <- validate_field(draft, "dtstart"),
             :ok <- validate_field(draft, "dtend") do
          {:ok, draft}
        end

      {:error, _} ->
        {:error, "invalid JSON in draft file"}
    end
  end

  @spec parse_update_draft(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp parse_update_draft(contents) do
    case Jason.decode(contents) do
      {:ok, draft} ->
        with :ok <- validate_field(draft, "uid"),
             :ok <- validate_field(draft, "etag"),
             :ok <- validate_field(draft, "href") do
          {:ok, draft}
        end

      {:error, _} ->
        {:error, "invalid JSON in update-draft file"}
    end
  end

  @spec validate_field(map(), String.t()) :: :ok | {:error, String.t()}
  defp validate_field(draft, field) do
    case Map.get(draft, field) do
      nil -> {:error, "missing required field: #{field}"}
      "" -> {:error, "empty required field: #{field}"}
      _ -> :ok
    end
  end

  # --- Utility ---

  @spec sanitize_uid(String.t()) :: String.t()
  defp sanitize_uid(uid) do
    uid
    |> String.replace(~r/[^\w.\-@]/, "_")
    |> String.slice(0, 200)
  end

  @spec generate_uid() :: String.t()
  defp generate_uid do
    random = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{random}@tri-onyx"
  end
end

defmodule TriOnyx.Connectors.Calendar.Poller do
  @moduledoc """
  GenServer that polls CalDAV for new/changed calendar events.

  Started conditionally by the application supervisor when CalDAV
  configuration is present. Tracks etags to detect changes.

  For each new or changed event:
  1. Fetches via CalDAV REPORT
  2. Writes event JSON to workspace
  3. Dispatches a `:unverified_input` trigger
  """

  use GenServer

  require Logger

  alias TriOnyx.Connectors.Calendar
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Workspace

  defstruct [
    :caldav_config,
    :agent_name,
    :calendars,
    :poll_interval_ms,
    :timer_ref,
    :known_etags
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    case Application.get_env(:tri_onyx, :calendar) do
      nil ->
        {:stop, :calendar_not_configured}

      config ->
        caldav = config[:caldav]

        state = %__MODULE__{
          caldav_config: caldav,
          agent_name: Map.get(caldav, :agent_name, "calendar"),
          calendars: Map.get(caldav, :calendars, ["personal"]),
          poll_interval_ms: Map.get(caldav, :poll_interval_ms, 900_000),
          timer_ref: nil,
          known_etags: load_known_etags(Map.get(caldav, :agent_name, "calendar"))
        }

        Logger.info(
          "Calendar poller starting for agent=#{state.agent_name} " <>
            "calendars=#{inspect(state.calendars)} interval=#{state.poll_interval_ms}ms"
        )

        send(self(), :poll)
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = do_poll(state)
    {:noreply, schedule_poll(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  @spec schedule_poll(%__MODULE__{}) :: %__MODULE__{}
  defp schedule_poll(state) do
    ref = Process.send_after(self(), :poll, state.poll_interval_ms)
    %{state | timer_ref: ref}
  end

  @spec do_poll(%__MODULE__{}) :: %__MODULE__{}
  defp do_poll(state) do
    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.agent_name])

    # Query window: past 7 days to future 90 days
    now = DateTime.utc_now()
    from = DateTime.add(now, -7, :day) |> DateTime.to_iso8601()
    to = DateTime.add(now, 90, :day) |> DateTime.to_iso8601()

    new_etags =
      Enum.reduce(state.calendars, state.known_etags, fn calendar, etags ->
        params = %{"calendar" => calendar, "from" => from, "to" => to}

        case Calendar.calendar_query(agent_dir, params) do
          {:ok, events} ->
            # Check for new/changed events
            Enum.each(events, fn event ->
              uid = event["uid"]
              etag = event["etag"]
              old_etag = Map.get(etags, uid)

              if uid && (old_etag == nil or old_etag != etag) do
                # Update risk manifest
                relative_path = "agents/#{state.agent_name}/events/#{calendar}/#{sanitize_uid(uid)}.json"

                Workspace.update_risk_manifest(
                  state.agent_name,
                  [relative_path],
                  :high,
                  :low
                )

                # Dispatch trigger
                trigger_payload =
                  "New/updated calendar event.\n" <>
                    "UID: #{uid}\n" <>
                    "Summary: #{event["summary"]}\n" <>
                    "Start: #{event["dtstart"]}\n" <>
                    "Calendar: #{calendar}\n" <>
                    "Path: /workspace/agents/#{state.agent_name}/events/#{calendar}/#{sanitize_uid(uid)}.json"

                TriggerRouter.dispatch(%{
                  type: :unverified_input,
                  agent_name: state.agent_name,
                  payload: trigger_payload
                })

                Logger.info("Calendar event #{uid} new/changed in #{calendar}")
              end
            end)

            # Update known etags for this calendar's events
            Enum.reduce(events, etags, fn event, acc ->
              if event["uid"] do
                Map.put(acc, event["uid"], event["etag"])
              else
                acc
              end
            end)

          {:error, reason} ->
            Logger.error("Calendar poll failed for #{calendar}: #{reason}")
            etags
        end
      end)

    # Write sync state
    write_sync_state(state.agent_name, new_etags)

    %{state | known_etags: new_etags}
  end

  @spec load_known_etags(String.t()) :: map()
  defp load_known_etags(agent_name) do
    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    state_path = Path.join([workspace_dir, "agents", agent_name, "state", "last_sync.json"])

    case File.read(state_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"etags" => etags}} when is_map(etags) -> etags
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @spec write_sync_state(String.t(), map()) :: :ok
  defp write_sync_state(agent_name, etags) do
    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    state_dir = Path.join([workspace_dir, "agents", agent_name, "state"])
    File.mkdir_p!(state_dir)
    state_path = Path.join(state_dir, "last_sync.json")

    state = %{
      "last_poll" => DateTime.to_iso8601(DateTime.utc_now()),
      "etags" => etags
    }

    File.write!(state_path, Jason.encode!(state, pretty: true))
    :ok
  end

  defp sanitize_uid(uid) do
    uid
    |> String.replace(~r/[^\w.\-@]/, "_")
    |> String.slice(0, 200)
  end
end
