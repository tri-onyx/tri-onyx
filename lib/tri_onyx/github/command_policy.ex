defmodule TriOnyx.GitHub.CommandPolicy do
  @moduledoc """
  Classifies GitHub tool invocations into policy verdicts.

  The GitHub tool is gateway-mediated: the agent never holds the repo
  token, so every remote operation passes through this policy before
  the gateway executes it on the agent's behalf. Verdicts:

  - `:allow` — executed immediately
  - `{:approval, reason}` — queued in `BCP.ApprovalQueue` for a human decision
  - `{:deny, reason}` — rejected outright

  ## Classification principles

  - Unknown or unclassifiable invocations fall back to `{:approval, _}`,
    never `:allow`. `gh api` in particular is a general API escape hatch,
    so anything not recognizably read-only requires a human in the loop.
  - Pushes that target a protected branch are denied — the sanctioned
    path to the default branch is a pull request. GitHub-side branch
    protection (plus a fine-grained token without bypass permission)
    remains the hard enforcement; this policy is the first gate.
  - Local git operations are not mediated at all: the agent has its
    clone via FUSE and runs local git through Bash. Only the verbs that
    need credentials (`push`, `fetch`, `pull`, `ls-remote`) are accepted
    here.
  """

  @protected_branches ~w(main master)

  # gh subcommands executed without approval. Reads plus the mutations
  # that make up the normal issue/PR working loop. Deliberately absent:
  # `pr merge` (lands on the base branch), `release *`, `workflow *`,
  # `repo edit/rename/archive` — those fall through to :approval.
  @gh_allow %{
    "issue" => ~w(list view status create comment edit close reopen develop),
    "pr" => ~w(list view diff checks status create comment edit review ready close reopen),
    "repo" => ~w(view list),
    "run" => ~w(list view watch rerun cancel download),
    "release" => ~w(list view download),
    "label" => ~w(list create edit delete),
    "search" => :any,
    "status" => :any,
    "cache" => ~w(list)
  }

  # gh command groups that are never executed, with or without approval.
  # `secret`/`variable` could plant exfiltration into CI; `auth`/`config`/
  # `alias` mutate the gateway's own gh state; `extension` installs code
  # that would run with the token; `codespace` spins up remote compute.
  @gh_deny %{
    "repo" => ~w(delete),
    "secret" => :any,
    "variable" => :any,
    "auth" => :any,
    "ssh-key" => :any,
    "gpg-key" => :any,
    "codespace" => :any,
    "extension" => :any,
    "alias" => :any,
    "config" => :any
  }

  # Flags on `gh api` that attach a request body (and flip the default
  # method to POST when no explicit method is given).
  @api_body_flags ~w(-f -F --field --raw-field --input)

  @doc "Branch names treated as protected push targets by default."
  @spec protected_branches() :: [String.t()]
  def protected_branches, do: @protected_branches

  @doc """
  Classifies a GitHub tool invocation.

  `command` is `"gh"` or `"git"`; `args` is the argv (without the leading
  binary name).

  ## Options

  - `:protected_branches` — branch names that may not be pushed to
    (default: `#{inspect(@protected_branches)}`)
  """
  @spec classify(String.t(), [String.t()], keyword()) ::
          :allow | {:approval, String.t()} | {:deny, String.t()}
  def classify(command, args, opts \\ [])

  def classify("gh", args, _opts), do: classify_gh(args)
  def classify("git", args, opts), do: classify_git(args, opts)

  def classify(other, _args, _opts) do
    {:deny, "unsupported command #{inspect(other)} — use \"gh\" or \"git\""}
  end

  # --- gh ---

  defp classify_gh([]), do: {:deny, "empty gh command"}

  defp classify_gh(["api" | rest]), do: classify_gh_api(rest)

  defp classify_gh([group | rest]) do
    sub = Enum.find(rest, &(not flag?(&1)))

    cond do
      matches?(@gh_deny, group, sub) ->
        {:deny, "gh #{Enum.join(Enum.reject([group, sub], &is_nil/1), " ")} is not allowed"}

      matches?(@gh_allow, group, sub) ->
        :allow

      true ->
        {:approval, "gh #{Enum.join(Enum.reject([group, sub], &is_nil/1), " ")} is not on the pre-approved command list"}
    end
  end

  defp classify_gh_api(args) do
    method = api_method(args)
    has_body = Enum.any?(args, &api_body_flag?/1)

    cond do
      method in ["GET", "HEAD"] ->
        # Explicit read-only method; -f/-F become query parameters.
        :allow

      is_nil(method) and not has_body ->
        # gh api defaults to GET when no body fields are given.
        :allow

      true ->
        {:approval, "gh api with method #{method || "POST"} mutates state"}
    end
  end

  defp api_method(args) do
    case Enum.split_while(args, &(&1 not in ["-X", "--method"])) do
      {_, [_flag, method | _]} ->
        String.upcase(method)

      _ ->
        Enum.find_value(args, fn arg ->
          case String.split(arg, "=", parts: 2) do
            [flag, method] when flag in ["-X", "--method"] -> String.upcase(method)
            _ -> nil
          end
        end)
    end
  end

  defp api_body_flag?(arg) do
    arg in @api_body_flags or
      Enum.any?(@api_body_flags, &String.starts_with?(arg, &1 <> "="))
  end

  defp matches?(table, group, sub) do
    case Map.get(table, group) do
      nil -> false
      :any -> true
      subs when is_list(subs) -> sub in subs
    end
  end

  # --- git ---

  defp classify_git([], _opts), do: {:deny, "empty git command"}

  defp classify_git(["push" | rest], opts) do
    protected = Keyword.get(opts, :protected_branches, @protected_branches)
    {flags, positional} = Enum.split_with(rest, &flag?/1)

    cond do
      "--mirror" in flags ->
        {:deny, "git push --mirror is not allowed"}

      "--all" in flags ->
        {:deny, "git push --all is not allowed (it could include protected branches)"}

      "--tags" in flags ->
        {:approval, "pushing tags requires approval"}

      length(positional) < 2 ->
        {:deny,
         "git push requires an explicit remote and branch " <>
           "(e.g. git push origin my-branch) so the gateway can check the target"}

      true ->
        [_remote | refspecs] = positional

        case Enum.find(refspecs, &targets_protected?(&1, protected)) do
          nil -> :allow
          refspec -> {:deny, "refusing push targeting protected branch (#{refspec}) — open a PR instead"}
        end
    end
  end

  defp classify_git([verb | _rest], _opts) when verb in ~w(fetch pull ls-remote), do: :allow

  defp classify_git([verb | _rest], _opts) do
    {:deny, "git #{verb} is not mediated — run local git operations via Bash in your clone"}
  end

  # A refspec targets a protected branch if its destination side (or the
  # whole refspec when there is no colon) names one. `+branch` is the
  # force-push prefix; `:branch` is a remote deletion.
  defp targets_protected?(refspec, protected) do
    dst =
      refspec
      |> String.trim_leading("+")
      |> String.split(":", parts: 2)
      |> List.last()

    strip_ref_prefix(dst) in protected
  end

  defp strip_ref_prefix("refs/heads/" <> branch), do: branch
  defp strip_ref_prefix(branch), do: branch

  defp flag?(arg), do: String.starts_with?(arg, "-")
end
