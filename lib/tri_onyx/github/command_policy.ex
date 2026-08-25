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
  - Local git operations are not mediated at all: the agent's clone is
    bind-mounted into its container at `/github/<owner>/<repo>`, so it
    runs local git through Bash. Only the verbs that need credentials
    (`push`, `fetch`, `pull`, `ls-remote`) are accepted here.
  - Every accepted git invocation is argv-guarded first
    (`@denied_git_options`, `remote_url_ok?/1`): git's transport and
    config options (`-c`, `--upload-pack`, `--receive-pack`, `--exec`, …)
    name programs the gateway would execute, so they are denied for all
    verbs regardless of the verb's own verdict.
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

  # Git options that turn an argv into code execution on the gateway, or
  # re-point git at another repository. `-c`/`--config`/`--config-env` can
  # set `core.sshCommand`, `credential.helper` or `alias.*`;
  # `--upload-pack`/`--receive-pack`/`--exec`/`-u` name the program the
  # transport runs on the other end (and `ext::`-style local transports run
  # it here); `--exec-path`/`--git-dir`/`--work-tree`/`-C` move git off the
  # clone the policy thinks it is guarding. None of them have a legitimate
  # use in a mediated invocation, for any verb.
  @denied_git_options ~w(-c -C --config --config-env --exec --exec-path
                         --upload-pack --receive-pack --git-dir --work-tree)

  # `-u` is `--upload-pack` on the fetch family but `--set-upstream` on
  # push, so it is denied per verb rather than globally.
  @upload_pack_short_verbs ~w(fetch pull clone ls-remote)

  # Push flags whose effective target the refspec check cannot vouch for.
  # `--all`/`--mirror` are denied outright above; these are gated instead.
  @push_approval_flags ~w(--tags --force -f --delete)

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

  defp classify_git(args, opts) do
    case guard_argv(args) do
      :ok -> classify_git_verb(args, opts)
      {:deny, _} = deny -> deny
    end
  end

  # Applies to every git invocation, before any verb-specific verdict:
  # both the option denylist and the remote check run over the whole argv,
  # so `git -c core.sshCommand=… fetch` and `git ls-remote ext::sh -c …`
  # are rejected the same way as their `clone` / `remote add` spellings.
  defp guard_argv(args) do
    cond do
      arg = Enum.find(args, &denied_option?/1) ->
        {:deny,
         "git option #{arg} is not allowed — it can make git execute a " <>
           "program or rewrite the gateway's git configuration."}

      upload_pack_short?(args) ->
        {:deny, "git option -u is --upload-pack for this command and is not allowed"}

      arg = Enum.find(args, &(not remote_url_ok?(&1))) ->
        {:deny,
         "git remote #{inspect(arg)} is not allowed — remotes must be a " <>
           "named remote (e.g. origin) or an https://github.com/... URL"}

      true ->
        :ok
    end
  end

  # Prefix match, so the `--opt=value` and attached-short-option spellings
  # (`--upload-pack=/bin/sh`, `-c core.sshCommand=…`) are covered too.
  defp denied_option?(arg), do: String.starts_with?(arg, @denied_git_options)

  defp upload_pack_short?(args) do
    Enum.any?(args, &(&1 in @upload_pack_short_verbs)) and
      Enum.any?(args, &String.starts_with?(&1, "-u"))
  end

  # An argv element that could name a transport target — an explicit
  # scheme, git's `helper::` remote syntax, scp-style `user@host:path`, or
  # a filesystem path — is acceptable only as an https://github.com/ URL.
  # Everything else (remote names, refspecs, branch names, flag values)
  # cannot name a host, a path or a program, so it passes through.
  defp remote_url_ok?(arg) do
    if remote_like?(arg) do
      String.starts_with?(arg, "https://github.com/") and not String.contains?(arg, "..")
    else
      true
    end
  end

  defp remote_like?(arg) do
    String.contains?(arg, "://") or String.contains?(arg, "::") or
      String.starts_with?(arg, ["/", "./", "../", "~"]) or
      Regex.match?(~r{\A[^/:]+@}, arg)
  end

  defp classify_git_verb(["push" | rest], opts) do
    protected = Keyword.get(opts, :protected_branches, @protected_branches)
    {flags, positional} = Enum.split_with(rest, &flag?/1)

    cond do
      "--mirror" in flags ->
        {:deny, "git push --mirror is not allowed"}

      "--all" in flags ->
        {:deny, "git push --all is not allowed (it could include protected branches)"}

      length(positional) < 2 ->
        # Bare `git push` pushes whatever the branch's upstream is, which
        # can be a protected branch — the gateway cannot check that here.
        {:deny,
         "git push requires an explicit remote and branch " <>
           "(e.g. git push origin my-branch) so the gateway can check the target"}

      true ->
        [_remote | refspecs] = positional

        cond do
          refspec = Enum.find(refspecs, &targets_protected?(&1, protected)) ->
            {:deny,
             "refusing push targeting protected branch (#{refspec}) — open a PR instead"}

          refspec = Enum.find(refspecs, &ambiguous_target?/1) ->
            # `git push origin HEAD` resolves server-side to the current
            # branch, so the literal refspec proves nothing about the target.
            {:approval,
             "push target #{inspect(refspec)} does not name a branch explicitly " <>
               "(it can resolve to a protected branch)"}

          flag = Enum.find(flags, &(&1 in @push_approval_flags)) ->
            {:approval, "git push #{flag} requires approval"}

          true ->
            :allow
        end
    end
  end

  defp classify_git_verb([verb | _rest], _opts) when verb in ~w(fetch pull ls-remote), do: :allow

  defp classify_git_verb([verb | _rest], _opts) do
    {:deny, "git #{verb} is not mediated — run local git operations via Bash in your clone"}
  end

  # A refspec targets a protected branch if its destination side (or the
  # whole refspec when there is no colon) names one. `+branch` is the
  # force-push prefix; `:branch` is a remote deletion.
  defp targets_protected?(refspec, protected), do: dst_ref(refspec) in protected

  # A destination that is `HEAD` (or empty) is resolved by git, not by the
  # refspec, so it cannot be cleared by the protected-branch check.
  defp ambiguous_target?(refspec), do: dst_ref(refspec) in ["HEAD", ""]

  defp dst_ref(refspec) do
    refspec
    |> String.trim_leading("+")
    |> String.split(":", parts: 2)
    |> List.last()
    |> strip_ref_prefix()
  end

  defp strip_ref_prefix("refs/heads/" <> branch), do: branch
  defp strip_ref_prefix(branch), do: branch

  defp flag?(arg), do: String.starts_with?(arg, "-")
end
