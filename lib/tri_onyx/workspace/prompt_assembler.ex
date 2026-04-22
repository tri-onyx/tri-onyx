defmodule TriOnyx.Workspace.PromptAssembler do
  @moduledoc """
  Builds enhanced system prompts from workspace context and agent definitions.

  Assembles a `<persona>` block from the workspace context files (soul,
  identity, user, daily memory, heartbeat) and appends the agent
  definition's system prompt body after a separator.

  Sections with nil or empty content are skipped. The daily memory section
  includes the date in its heading.
  """

  alias TriOnyx.AgentDefinition

  @doc """
  Assembles a complete system prompt from the agent definition and
  workspace context.

  The prompt structure is:

      <persona>
      # Soul
      ...
      # Identity
      ...
      # User
      ...
      # Recent Memory — YYYY-MM-DD
      ...
      # Notes
      ...
      # Heartbeat
      ...
      </persona>

      ---

      {agent definition system prompt}

  Sections are omitted if their content is nil or empty string.
  """
  @spec assemble(AgentDefinition.t(), map()) :: String.t()
  def assemble(%AgentDefinition{} = definition, workspace_context) when is_map(workspace_context) do
    persona_sections = build_persona_sections(workspace_context)

    persona_block =
      if persona_sections == "" do
        ""
      else
        "<persona>\n#{persona_sections}</persona>\n\n---\n\n"
      end

    memory_instructions = build_memory_instructions(definition.name)

    persona_block <> (definition.system_prompt || "") <> memory_instructions
  end

  # --- Private Helpers ---

  @heartbeat_max_bytes 16_384

  @spec build_persona_sections(map()) :: String.t()
  defp build_persona_sections(context) do
    today = Date.utc_today() |> Date.to_iso8601()

    sections =
      [
        {"# Soul", Map.get(context, :soul)},
        {"# Identity", Map.get(context, :identity)},
        {"# User", Map.get(context, :user)},
        {"# Recent Memory \u2014 #{today}", Map.get(context, :daily_memory)},
        {"# Notes", Map.get(context, :notes)},
        {"# Heartbeat", context |> Map.get(:heartbeat) |> truncate_tail(@heartbeat_max_bytes)}
      ]
      |> Enum.filter(fn {_heading, content} -> present?(content) end)
      |> Enum.map(fn {heading, content} -> "#{heading}\n#{content}\n" end)

    Enum.join(sections, "\n")
  end

  @spec build_memory_instructions(String.t()) :: String.t()
  defp build_memory_instructions(agent_name) do
    today = Date.utc_today() |> Date.to_iso8601()

    """

    ## Memory system

    You have a persistent memory system. Previous memories appear in the `<persona>` block above under "# Recent Memory", "# Notes", and "# Heartbeat".

    To save new memories, write to these files using the Write tool:

    - **Daily memory**: `/workspace/agents/#{agent_name}/memory/#{today}.md` — append notes about what you worked on, key findings, and unfinished tasks. If the file already has content, read it first and append rather than overwrite.
    - **Notes**: `/workspace/agents/#{agent_name}/NOTES.md` — corrections, preferences, and lessons learned. When corrected, append the lesson under a descriptive heading.
    - **Heartbeat**: `/workspace/agents/#{agent_name}/HEARTBEAT.md` — update with your current state, ongoing work, and anything the next session should know immediately.

    **Important:** Before writing to a file, you must Read it first. Always read each file in its own separate tool call — never read memory files in parallel with other reads. If a parallel read fails, the sibling reads are also marked as failed and subsequent writes will be blocked.

    You can write to these files at any time during a session, not just at shutdown. Keep entries concise and useful for future sessions.
    """
  end

  @spec truncate_tail(String.t() | nil, pos_integer()) :: String.t() | nil
  defp truncate_tail(nil, _max_bytes), do: nil
  defp truncate_tail(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_tail(text, max_bytes) do
    tail = binary_part(text, byte_size(text) - max_bytes, max_bytes)

    # Drop the first partial line so we start on a clean boundary
    trimmed =
      case :binary.match(tail, "\n") do
        {pos, 1} -> binary_part(tail, pos + 1, byte_size(tail) - pos - 1)
        :nomatch -> tail
      end

    "[truncated — showing last #{div(max_bytes, 1024)} KB of heartbeat]\n\n" <> trimmed
  end

  @spec present?(term()) :: boolean()
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
