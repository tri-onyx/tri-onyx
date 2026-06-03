defmodule TriOnyx.Workspace.PromptAssembler do
  @moduledoc """
  Builds enhanced system prompts from workspace context and agent definitions.

  Assembles a `<persona>` block from the workspace context files (soul,
  identity, user, daily memory, notes) and appends the agent definition's
  system prompt body after a separator.

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
      # Notes
      ...
      # Recent Memory — YYYY-MM-DD
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

  @spec build_persona_sections(map()) :: String.t()
  defp build_persona_sections(context) do
    today = Date.utc_today() |> Date.to_iso8601()

    sections =
      [
        {"# Soul", Map.get(context, :soul)},
        {"# Identity", Map.get(context, :identity)},
        {"# User", Map.get(context, :user)},
        {"# Notes", Map.get(context, :notes)},
        {"# Recent Memory \u2014 #{today}", Map.get(context, :daily_memory)}
      ]
      |> Enum.filter(fn {_heading, content} -> present?(content) end)
      |> Enum.map(fn {heading, content} ->
        if String.starts_with?(content, "# ") do
          "#{content}\n"
        else
          "#{heading}\n#{content}\n"
        end
      end)

    Enum.join(sections, "\n")
  end

  @spec build_memory_instructions(String.t()) :: String.t()
  defp build_memory_instructions(agent_name) do
    today = Date.utc_today() |> Date.to_iso8601()

    """

    ## Memory system

    You have a persistent memory system. Previous memories appear in the `<persona>` block above under "# Recent Memory" and "# Notes".

    To save new memories, write to these files using the Write tool:

    - **Daily memory**: `/workspace/agents/#{agent_name}/memory/#{today}.md` — append notes about what you worked on, key findings, and unfinished tasks. If the file already has content, read it first and append rather than overwrite.
    - **Notes**: `/workspace/agents/#{agent_name}/NOTES.md` — corrections, preferences, and lessons learned. When corrected, append the lesson under a descriptive heading. This file has a strict size limit — keep entries concise and prune outdated notes when adding new ones.

    **Important:** Before writing to a file, you must Read it first. Always read each file in its own separate tool call — never read memory files in parallel with other reads. If a parallel read fails, the sibling reads are also marked as failed and subsequent writes will be blocked.

    You can write to these files at any time during a session, not just at shutdown. Keep entries concise and useful for future sessions.
    """
  end

  @spec present?(term()) :: boolean()
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
