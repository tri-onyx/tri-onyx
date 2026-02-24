defmodule TriOnyx.Connectors.Email do
  @moduledoc """
  Email connector for TriOnyx agents.

  Provides SMTP sending, IMAP folder operations, and MIME parsing.
  Credentials are held by the gateway — agents never see them.

  ## Public API

  - `send_email/1` — reads a draft JSON file and sends via SMTP
  - `move_email/4` — moves an email between IMAP folders + filesystem
  - `create_folder/2` — creates an IMAP folder + filesystem directory
  """

  require Logger

  @doc """
  Sends an email from a draft JSON file.

  The draft must contain `to`, `subject`, and `body` fields.
  Optional: `cc`, `in_reply_to`.

  Returns `{:ok, message_id}` on success.
  """
  @spec send_email(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def send_email(host_draft_path) do
    with {:ok, contents} <- read_draft(host_draft_path),
         {:ok, draft} <- parse_draft(contents),
         {:ok, config} <- get_smtp_config(),
         {:ok, message_id} <- deliver_smtp(draft, config) do
      {:ok, message_id}
    end
  end

  @doc """
  Moves an email between IMAP folders and syncs the filesystem.

  Moves the email directory from `{workspace_agent_dir}/{source_folder}/{uid}/`
  to `{workspace_agent_dir}/{dest_folder}/{uid}/`.

  Also performs the IMAP MOVE (or COPY + STORE \\Deleted + EXPUNGE).
  """
  @spec move_email(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :moved} | {:error, String.t()}
  def move_email(uid, source_folder, dest_folder, workspace_agent_dir) do
    source_dir = Path.join([workspace_agent_dir, source_folder, uid])
    dest_parent = Path.join(workspace_agent_dir, dest_folder)
    dest_dir = Path.join(dest_parent, uid)

    with :ok <- validate_folder_name(source_folder),
         :ok <- validate_folder_name(dest_folder),
         :ok <- imap_move(uid, source_folder, dest_folder),
         true <- File.dir?(source_dir) || {:error, "source email directory not found: #{source_dir}"},
         :ok <- File.mkdir_p(dest_parent),
         :ok <- rename_email_dir(source_dir, dest_dir) do
      Logger.info("Email #{uid} moved from #{source_folder} to #{dest_folder}")
      {:ok, :moved}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "filesystem move failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Creates a new email folder on IMAP and the local filesystem.

  Creates `{workspace_agent_dir}/{folder_name}/`.
  """
  @spec create_folder(String.t(), String.t()) :: {:ok, :created} | {:error, String.t()}
  def create_folder(folder_name, workspace_agent_dir) do
    with :ok <- validate_folder_name(folder_name),
         :ok <- imap_create_folder(folder_name) do
      folder_path = Path.join(workspace_agent_dir, folder_name)

      case File.mkdir_p(folder_path) do
        :ok ->
          Logger.info("Email folder created: #{folder_name}")
          {:ok, :created}

        {:error, reason} ->
          {:error, "failed to create folder: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Parses a raw MIME email binary into a structured map.

  Uses `gen_smtp`'s MIME utilities to decode headers, extract text/html
  bodies, and enumerate attachments.
  """
  @spec parse_mime(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse_mime(raw_email) when is_binary(raw_email) do
    try do
      {_type, _subtype, headers, _params, body} = :mimemail.decode(raw_email)

      text_body = extract_body(body, "text", "plain")
      html_body = extract_body(body, "text", "html")
      attachments = extract_attachments(body)

      message = %{
        "message_id" => get_header(headers, "Message-ID"),
        "from" => get_header(headers, "From"),
        "to" => get_header(headers, "To"),
        "cc" => get_header(headers, "Cc"),
        "subject" => get_header(headers, "Subject"),
        "date" => get_header(headers, "Date"),
        "body_text" => text_body || "",
        "body_html" => html_body || "",
        "headers" => %{
          "reply-to" => get_header(headers, "Reply-To"),
          "in-reply-to" => get_header(headers, "In-Reply-To")
        },
        "attachments" => attachments
      }

      {:ok, message}
    rescue
      e -> {:error, "MIME parsing failed: #{Exception.message(e)}"}
    end
  end

  @doc """
  Writes a parsed email to a directory as `message.json` + attachment files.

  Returns the list of written file paths.
  """
  @spec write_email_dir(String.t(), String.t(), map(), [{String.t(), binary()}]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def write_email_dir(base_dir, uid, message, attachment_data) do
    email_dir = Path.join(base_dir, uid)

    with :ok <- File.mkdir_p(email_dir) do
      message_path = Path.join(email_dir, "message.json")
      message_with_uid = Map.put(message, "uid", uid)
      File.write!(message_path, Jason.encode!(message_with_uid, pretty: true))

      written_files = [message_path]

      attachment_files =
        attachment_data
        |> Enum.with_index(1)
        |> Enum.map(fn {{filename, data}, idx} ->
          safe_name = "attachment-#{idx}-#{sanitize_filename(filename)}"
          path = Path.join(email_dir, safe_name)
          File.write!(path, data)
          path
        end)

      {:ok, written_files ++ attachment_files}
    end
  end

  # --- Private Helpers ---

  @spec read_draft(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_draft(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "cannot read draft: #{inspect(reason)}"}
    end
  end

  @spec parse_draft(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp parse_draft(contents) do
    case Jason.decode(contents) do
      {:ok, draft} ->
        with :ok <- validate_draft_field(draft, "to"),
             :ok <- validate_draft_field(draft, "subject"),
             :ok <- validate_draft_field(draft, "body"),
             :ok <- validate_email_address(draft["to"]) do
          if cc = draft["cc"] do
            case validate_email_address(cc) do
              :ok -> {:ok, draft}
              error -> error
            end
          else
            {:ok, draft}
          end
        end

      {:error, _} ->
        {:error, "invalid JSON in draft file"}
    end
  end

  @spec validate_draft_field(map(), String.t()) :: :ok | {:error, String.t()}
  defp validate_draft_field(draft, field) do
    case Map.get(draft, field) do
      nil -> {:error, "missing required field: #{field}"}
      "" -> {:error, "empty required field: #{field}"}
      _ -> :ok
    end
  end

  @spec validate_email_address(String.t()) :: :ok | {:error, String.t()}
  defp validate_email_address(address) when is_binary(address) do
    # Basic email validation: must contain @ with text on both sides
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, String.trim(address)) do
      :ok
    else
      {:error, "invalid email address: #{address}"}
    end
  end

  defp validate_email_address(_), do: {:error, "email address must be a string"}

  @spec validate_folder_name(String.t()) :: :ok | {:error, String.t()}
  defp validate_folder_name(name) do
    cond do
      String.contains?(name, "..") ->
        {:error, "folder name must not contain path traversal: #{name}"}

      String.contains?(name, "/") ->
        {:error, "folder name must not contain path separators: #{name}"}

      not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) ->
        {:error, "folder name must be alphanumeric with hyphens/underscores: #{name}"}

      true ->
        :ok
    end
  end

  # Renames an email directory, replacing the destination if it already exists.
  # This handles the case where a previous session moved the email locally but
  # the inbox was re-fetched — the source (inbox copy) is authoritative.
  @spec rename_email_dir(String.t(), String.t()) :: :ok | {:error, term()}
  defp rename_email_dir(source, dest) do
    case File.rename(source, dest) do
      :ok -> :ok
      {:error, :eexist} ->
        File.rm_rf!(dest)
        File.rename(source, dest)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_smtp_config() :: {:ok, map()} | {:error, String.t()}
  defp get_smtp_config do
    case Application.get_env(:tri_onyx, :email) do
      nil -> {:error, "email not configured (TRI_ONYX_IMAP_HOST not set)"}
      config -> {:ok, config[:smtp]}
    end
  end

  @spec deliver_smtp(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defp deliver_smtp(draft, smtp_config) do
    to = draft["to"]
    subject = draft["subject"]
    body = draft["body"]
    cc = draft["cc"]
    in_reply_to = draft["in_reply_to"]

    from = smtp_config.username
    message_id = "<#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}@tri_onyx>"

    headers =
      [
        {"From", from},
        {"To", to},
        {"Subject", subject},
        {"Message-ID", message_id},
        {"Date", Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")},
        {"MIME-Version", "1.0"},
        {"Content-Type", "text/plain; charset=utf-8"}
      ]
      |> maybe_add_header("Cc", cc)
      |> maybe_add_header("In-Reply-To", in_reply_to)

    header_str = Enum.map_join(headers, "\r\n", fn {k, v} -> "#{k}: #{v}" end)
    email_body = header_str <> "\r\n\r\n" <> body

    relay = String.to_charlist(smtp_config.host)
    port = smtp_config.port
    username = smtp_config.username
    password = smtp_config.password

    recipients = [to | if(cc, do: [cc], else: [])]

    ssl? = Map.get(smtp_config, :ssl, true)

    cacerts =
      try do
        :public_key.cacerts_get()
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    ssl_opts =
      [
        server_name_indication: relay,
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ] ++
        cond do
          is_list(cacerts) and cacerts != [] ->
            [verify: :verify_peer, cacerts: cacerts]

          File.exists?("/etc/ssl/certs/ca-certificates.crt") ->
            [verify: :verify_peer, cacertfile: ~c"/etc/ssl/certs/ca-certificates.crt"]

          true ->
            [verify: :verify_none]
        end

    options =
      [
        relay: relay,
        port: port,
        username: username,
        password: password
      ] ++
        cond do
          # Port 465 = implicit SSL (entire connection wrapped in TLS)
          # gen_smtp uses `sockopts` for the initial SSL socket options
          ssl? and port == 465 ->
            [ssl: true, tls: :never, sockopts: ssl_opts]

          # Port 587/25 = STARTTLS (upgrade plaintext to TLS)
          # gen_smtp uses `tls_options` for the STARTTLS upgrade
          ssl? ->
            [tls: :always, tls_options: ssl_opts]

          true ->
            [tls: :never]
        end

    case :gen_smtp_client.send_blocking({from, recipients, email_body}, options) do
      receipt when is_binary(receipt) ->
        Logger.info("Email sent to #{to} (message_id=#{message_id})")
        {:ok, message_id}

      {:error, reason} ->
        {:error, "SMTP send failed: #{inspect(reason)}"}

      {:error, type, detail} ->
        {:error, "SMTP send failed: #{inspect(type)} — #{inspect(detail)}"}
    end
  end

  @spec maybe_add_header([{String.t(), String.t()}], String.t(), String.t() | nil) ::
          [{String.t(), String.t()}]
  defp maybe_add_header(headers, _key, nil), do: headers
  defp maybe_add_header(headers, _key, ""), do: headers
  defp maybe_add_header(headers, key, value), do: headers ++ [{key, value}]

  # --- MIME extraction helpers ---

  @spec get_header([{String.t(), String.t()}], String.t()) :: String.t()
  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> ""
    end
  end

  @spec extract_body(term(), String.t(), String.t()) :: String.t() | nil
  defp extract_body(body, type, subtype) when is_list(body) do
    Enum.find_value(body, fn
      {^type, ^subtype, _headers, _params, content} when is_binary(content) -> content
      {_, _, _headers, _params, nested} when is_list(nested) -> extract_body(nested, type, subtype)
      _ -> nil
    end)
  end

  defp extract_body(content, _type, _subtype) when is_binary(content), do: content
  defp extract_body(_, _, _), do: nil

  @spec extract_attachments(term()) :: [map()]
  defp extract_attachments(body) when is_list(body) do
    Enum.flat_map(body, fn
      {type, _subtype, headers, params, content} when is_binary(content) ->
        disposition = get_header(headers, "Content-Disposition")

        if String.starts_with?(disposition, "attachment") or
             (type != "text" and type != "multipart") do
          filename =
            extract_filename(params) || extract_filename_from_disposition(disposition) || "unnamed"

          [
            %{
              "filename" => filename,
              "content_type" => "#{type}/#{get_header(headers, "Content-Type") || "octet-stream"}",
              "size" => byte_size(content)
            }
          ]
        else
          []
        end

      {_, _, _headers, _params, nested} when is_list(nested) ->
        extract_attachments(nested)

      _ ->
        []
    end)
  end

  defp extract_attachments(_), do: []

  @spec extract_filename(map() | list()) :: String.t() | nil
  defp extract_filename(params) when is_map(params) do
    Map.get(params, "name") || Map.get(params, "filename")
  end

  defp extract_filename(_), do: nil

  @spec extract_filename_from_disposition(String.t()) :: String.t() | nil
  defp extract_filename_from_disposition(disposition) do
    case Regex.run(~r/filename="?([^";]+)"?/, disposition) do
      [_, filename] -> filename
      _ -> nil
    end
  end

  @spec sanitize_filename(String.t()) :: String.t()
  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^\w.\-]/, "_")
    |> String.slice(0, 100)
  end

  # --- IMAP connection and operation helpers ---

  @doc false
  @spec with_imap_connection(map(), (port(), atom() -> term())) :: term()
  def with_imap_connection(imap, fun) do
    host = String.to_charlist(imap.host)
    port = imap.port
    ssl_opts = if imap.ssl, do: [verify: :verify_none], else: []

    try do
      {:ok, socket} =
        if imap.ssl do
          :ssl.connect(host, port, [{:active, false}, :binary | ssl_opts])
        else
          :gen_tcp.connect(host, port, [{:active, false}, :binary])
        end

      transport = if imap.ssl, do: :ssl, else: :gen_tcp

      {:ok, _greeting} = imap_recv_line(socket, transport)

      imap_send(socket, transport, "A001 LOGIN #{imap.username} #{imap.password}")
      {:ok, login_resp} = imap_recv_line(socket, transport)

      unless String.contains?(login_resp, "OK") do
        transport.close(socket)
        throw({:error, "IMAP LOGIN failed: #{login_resp}"})
      end

      try do
        fun.(socket, transport)
      after
        try do
          imap_send(socket, transport, "ZZZZ LOGOUT")
          transport.close(socket)
        catch
          _, _ -> :ok
        end
      end
    rescue
      e -> {:error, "IMAP connection failed: #{Exception.message(e)}"}
    catch
      {:error, _} = err -> err
    end
  end

  @doc false
  def imap_send(socket, :ssl, command), do: :ssl.send(socket, command <> "\r\n")
  def imap_send(socket, :gen_tcp, command), do: :gen_tcp.send(socket, command <> "\r\n")

  @doc false
  def imap_recv_line(socket, :ssl), do: :ssl.recv(socket, 0, 30_000)
  def imap_recv_line(socket, :gen_tcp), do: :gen_tcp.recv(socket, 0, 30_000)

  @doc false
  def imap_recv_until_tagged(socket, transport, tag) do
    imap_recv_until_tagged(socket, transport, tag, "")
  end

  @doc false
  def imap_recv_until_tagged(socket, transport, tag, acc) do
    case imap_recv_line(socket, transport) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(data, "#{tag} OK") or String.contains?(data, "#{tag} NO") or
             String.contains?(data, "#{tag} BAD") do
          {:ok, acc}
        else
          imap_recv_until_tagged(socket, transport, tag, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_imap_config() :: {:ok, map()} | :not_configured
  defp get_imap_config do
    case Application.get_env(:tri_onyx, :email) do
      nil -> :not_configured
      config -> {:ok, config[:imap]}
    end
  end

  @spec imap_move(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  defp imap_move(uid, source_folder, dest_folder) do
    case get_imap_config() do
      :not_configured ->
        :ok

      {:ok, imap} ->
        # Ensure destination folder exists on the IMAP server before moving
        with :ok <- imap_create_folder(dest_folder) do
          with_imap_connection(imap, fn socket, transport ->
            # SELECT source folder (normalize "inbox" to "INBOX" for IMAP)
            imap_folder = normalize_imap_folder(source_folder)
            imap_send(socket, transport, "M001 SELECT #{imap_folder}")
            {:ok, select_resp} = imap_recv_until_tagged(socket, transport, "M001")

            if not String.contains?(select_resp, "M001 OK") do
              {:error, "IMAP SELECT failed for #{imap_folder}: #{String.trim(select_resp)}"}
            else
              # Try UID MOVE (RFC 6851)
              imap_dest = normalize_imap_folder(dest_folder)
              imap_send(socket, transport, "M002 UID MOVE #{uid} #{imap_dest}")
              {:ok, move_resp} = imap_recv_until_tagged(socket, transport, "M002")

              if String.contains?(move_resp, "M002 OK") do
                :ok
              else
                # Fallback: COPY + STORE \Deleted + EXPUNGE for older servers
                imap_send(socket, transport, "M003 UID COPY #{uid} #{imap_dest}")
                {:ok, copy_resp} = imap_recv_until_tagged(socket, transport, "M003")

                if String.contains?(copy_resp, "M003 OK") do
                  imap_send(socket, transport, "M004 UID STORE #{uid} +FLAGS (\\Deleted)")
                  {:ok, _} = imap_recv_until_tagged(socket, transport, "M004")

                  imap_send(socket, transport, "M005 EXPUNGE")
                  {:ok, _} = imap_recv_until_tagged(socket, transport, "M005")
                  :ok
                else
                  {:error, "IMAP MOVE/COPY failed: #{String.trim(copy_resp)}"}
                end
              end
            end
          end)
        end
    end
  end

  defp normalize_imap_folder(folder) do
    if String.downcase(folder) == "inbox", do: "INBOX", else: folder
  end

  @spec imap_create_folder(String.t()) :: :ok | {:error, String.t()}
  defp imap_create_folder(folder_name) do
    case get_imap_config() do
      :not_configured ->
        :ok

      {:ok, imap} ->
        with_imap_connection(imap, fn socket, transport ->
          imap_name = normalize_imap_folder(folder_name)
          imap_send(socket, transport, "C001 CREATE #{imap_name}")
          {:ok, create_resp} = imap_recv_until_tagged(socket, transport, "C001")

          if String.contains?(create_resp, "C001 OK") or
               String.contains?(create_resp, "[ALREADYEXISTS]") do
            :ok
          else
            {:error, "IMAP CREATE failed: #{String.trim(create_resp)}"}
          end
        end)
    end
  end
end

defmodule TriOnyx.Connectors.Email.Poller do
  @moduledoc """
  GenServer that polls IMAP for new emails and writes them to agent workspaces.

  Started conditionally by the application supervisor when email configuration
  is present. Tracks the last-seen UID to only fetch new messages.

  For each new email:
  1. Fetches and parses the MIME structure
  2. Writes `{workspace}/agents/{agent_name}/inbox/{uid}/message.json` + attachments
  3. Updates the risk manifest with `taint_level: :high`
  4. Dispatches a `:unverified_input` trigger via `TriggerRouter`
  """

  use GenServer

  require Logger

  alias TriOnyx.Connectors.Email
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Workspace

  defstruct [
    :imap_config,
    :agent_name,
    :poll_interval_ms,
    :last_uid,
    :timer_ref
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    case Application.get_env(:tri_onyx, :email) do
      nil ->
        {:stop, :email_not_configured}

      config ->
        imap = config[:imap]
        last_uid = last_uid_from_disk(imap.agent_name)

        state = %__MODULE__{
          imap_config: imap,
          agent_name: imap.agent_name,
          poll_interval_ms: imap.poll_interval_ms,
          last_uid: last_uid,
          timer_ref: nil
        }

        Logger.info(
          "Email poller starting for agent=#{state.agent_name} " <>
            "host=#{imap.host} last_uid=#{last_uid} interval=#{state.poll_interval_ms}ms"
        )

        # Poll immediately on startup, then on interval
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

  # Reads the persisted last-seen UID from the agent's state directory.
  # Falls back to scanning the inbox directory for backwards compatibility,
  # and "0" if neither source has data.
  @spec last_uid_from_disk(String.t()) :: String.t()
  defp last_uid_from_disk(agent_name) do
    case read_last_uid_file(agent_name) do
      {:ok, uid} ->
        uid

      :error ->
        # Backwards compat: derive from inbox contents if no state file yet
        workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
        inbox_dir = Path.join([workspace_dir, "agents", agent_name, "inbox"])

        case File.ls(inbox_dir) do
          {:ok, entries} ->
            entries
            |> Enum.map(fn entry -> Integer.parse(entry) end)
            |> Enum.filter(fn
              {_n, ""} -> true
              _ -> false
            end)
            |> Enum.map(fn {n, ""} -> n end)
            |> Enum.max(fn -> 0 end)
            |> Integer.to_string()

          {:error, _} ->
            "0"
        end
    end
  end

  @spec last_uid_state_path(String.t()) :: String.t()
  defp last_uid_state_path(agent_name) do
    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    Path.join([workspace_dir, "agents", agent_name, "state", "last_uid"])
  end

  @spec read_last_uid_file(String.t()) :: {:ok, String.t()} | :error
  defp read_last_uid_file(agent_name) do
    path = last_uid_state_path(agent_name)

    case File.read(path) do
      {:ok, contents} ->
        uid = String.trim(contents)

        case Integer.parse(uid) do
          {_n, ""} -> {:ok, uid}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  @spec persist_last_uid(String.t(), String.t()) :: :ok
  defp persist_last_uid(agent_name, uid) do
    path = last_uid_state_path(agent_name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, uid)
    :ok
  end

  @spec schedule_poll(%__MODULE__{}) :: %__MODULE__{}
  defp schedule_poll(state) do
    ref = Process.send_after(self(), :poll, state.poll_interval_ms)
    %{state | timer_ref: ref}
  end

  @spec do_poll(%__MODULE__{}) :: %__MODULE__{}
  defp do_poll(state) do
    imap = state.imap_config

    case connect_and_fetch(imap, state.last_uid) do
      {:ok, emails, new_last_uid} ->
        workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
        inbox_dir = Path.join([workspace_dir, "agents", state.agent_name, "inbox"])

        Enum.each(emails, fn {uid, raw_email} ->
          email_dir = Path.join(inbox_dir, uid)

          if File.dir?(email_dir) do
            Logger.debug("Email #{uid} already in inbox, skipping")
          else
          case Email.parse_mime(raw_email) do
            {:ok, message} ->
              attachment_data = extract_raw_attachments(raw_email)

              case Email.write_email_dir(inbox_dir, uid, message, attachment_data) do
                {:ok, _files} ->
                  # Update risk manifest
                  relative_paths =
                    ["agents/#{state.agent_name}/inbox/#{uid}/message.json"]

                  Workspace.update_risk_manifest(
                    state.agent_name,
                    relative_paths,
                    :high,
                    :low
                  )

                  # Dispatch connector trigger
                  trigger_payload =
                    "New email received.\n" <>
                      "UID: #{uid}\n" <>
                      "From: #{message["from"]}\n" <>
                      "Subject: #{message["subject"]}\n" <>
                      "Path: /workspace/agents/#{state.agent_name}/inbox/#{uid}/message.json"

                  TriggerRouter.dispatch(%{
                    type: :unverified_input,
                    agent_name: state.agent_name,
                    payload: trigger_payload
                  })

                  Logger.info("Email #{uid} written to inbox for agent #{state.agent_name}")

                {:error, reason} ->
                  Logger.error("Failed to write email #{uid}: #{reason}")
              end

            {:error, reason} ->
              Logger.error("Failed to parse email #{uid}: #{reason}")
          end
          end
        end)

        persist_last_uid(state.agent_name, new_last_uid)
        %{state | last_uid: new_last_uid}

      {:error, reason} ->
        Logger.error("IMAP poll failed: #{inspect(reason)}")
        state
    end
  end

  @spec connect_and_fetch(map(), String.t()) ::
          {:ok, [{String.t(), binary()}], String.t()} | {:error, term()}
  defp connect_and_fetch(imap, last_uid) do
    Email.with_imap_connection(imap, fn socket, transport ->
      # Select INBOX
      Email.imap_send(socket, transport, "A002 SELECT INBOX")
      {:ok, _select_resp} = Email.imap_recv_until_tagged(socket, transport, "A002")

      # Search for new messages (IMAP UIDs start at 1, never 0)
      search_from = if last_uid == "0", do: "1", else: last_uid
      Email.imap_send(socket, transport, "A003 SEARCH UID #{search_from}:*")
      {:ok, search_resp} = Email.imap_recv_until_tagged(socket, transport, "A003")

      uids = parse_search_response(search_resp, last_uid)

      # Fetch each new message
      emails =
        uids
        |> Enum.map(fn uid ->
          Email.imap_send(socket, transport, "F#{uid} FETCH #{uid} (BODY[])")
          {:ok, fetch_resp} = Email.imap_recv_until_tagged(socket, transport, "F#{uid}")
          {uid, extract_body_from_fetch(fetch_resp)}
        end)
        |> Enum.reject(fn {_uid, body} -> body == "" end)

      new_last_uid =
        case uids do
          [] -> last_uid
          _ -> List.last(uids)
        end

      {:ok, emails, new_last_uid}
    end)
  end

  defp parse_search_response(response, last_uid) do
    case Regex.run(~r/\* SEARCH (.+)/, response) do
      [_, uid_str] ->
        uid_str
        |> String.split()
        |> Enum.reject(fn uid -> uid == last_uid end)

      _ ->
        []
    end
  end

  defp extract_body_from_fetch(response) do
    # Extract the raw message body between BODY[] literal markers
    case Regex.run(~r/\{(\d+)\}\r?\n/s, response) do
      [match, size_str] ->
        size = String.to_integer(size_str)
        start = :binary.match(response, match) |> elem(0)
        offset = start + byte_size(match)

        if offset + size <= byte_size(response) do
          binary_part(response, offset, size)
        else
          ""
        end

      _ ->
        ""
    end
  end

  defp extract_raw_attachments(raw_email) do
    try do
      {_type, _subtype, _headers, _params, body} = :mimemail.decode(raw_email)
      do_extract_raw_attachments(body)
    rescue
      _ -> []
    end
  end

  defp do_extract_raw_attachments(body) when is_list(body) do
    Enum.flat_map(body, fn
      {type, _subtype, headers, params, content} when is_binary(content) ->
        disposition =
          case List.keyfind(headers, "Content-Disposition", 0) do
            {_, v} -> v
            nil -> ""
          end

        if String.starts_with?(disposition, "attachment") or
             (type != "text" and type != "multipart") do
          filename =
            (is_map(params) && (params["name"] || params["filename"])) || "unnamed"

          [{filename, content}]
        else
          []
        end

      {_, _, _headers, _params, nested} when is_list(nested) ->
        do_extract_raw_attachments(nested)

      _ ->
        []
    end)
  end

  defp do_extract_raw_attachments(_), do: []
end
