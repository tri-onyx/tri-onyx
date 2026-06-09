defmodule TriOnyx.Connectors.Util do
  @moduledoc """
  Helpers shared by the gateway-side connectors (CalDAV calendar,
  IMAP/SMTP email): transport-agnostic socket IO, draft-file reading and
  validation, and UID sanitization for filesystem paths.
  """

  @recv_timeout_ms 30_000

  # --- Transport-agnostic socket IO ---

  @spec send_data(term(), :ssl | :gen_tcp, iodata()) :: :ok | {:error, term()}
  def send_data(socket, :ssl, data), do: :ssl.send(socket, data)
  def send_data(socket, :gen_tcp, data), do: :gen_tcp.send(socket, data)

  @spec recv_data(term(), :ssl | :gen_tcp) :: {:ok, binary()} | {:error, term()}
  def recv_data(socket, :ssl), do: :ssl.recv(socket, 0, @recv_timeout_ms)
  def recv_data(socket, :gen_tcp), do: :gen_tcp.recv(socket, 0, @recv_timeout_ms)

  @spec transport_close(term(), :ssl | :gen_tcp) :: :ok | {:error, term()}
  def transport_close(socket, :ssl), do: :ssl.close(socket)
  def transport_close(socket, :gen_tcp), do: :gen_tcp.close(socket)

  # --- Draft files ---

  @spec read_draft(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_draft(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "cannot read draft: #{inspect(reason)}"}
    end
  end

  @spec validate_field(map(), String.t()) :: :ok | {:error, String.t()}
  def validate_field(draft, field) do
    case Map.get(draft, field) do
      nil -> {:error, "missing required field: #{field}"}
      "" -> {:error, "empty required field: #{field}"}
      _ -> :ok
    end
  end

  # --- UID sanitization ---

  @doc """
  Makes an externally-supplied UID safe for use as a filename component.
  Keeps word characters, `.`, `-`, `@`; everything else becomes `_`.
  """
  @spec sanitize_uid(String.t()) :: String.t()
  def sanitize_uid(uid) do
    uid
    |> String.replace(~r/[^\w.\-@]/, "_")
    |> String.slice(0, 200)
  end
end
