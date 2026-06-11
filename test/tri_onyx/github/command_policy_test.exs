defmodule TriOnyx.GitHub.CommandPolicyTest do
  use ExUnit.Case, async: true

  alias TriOnyx.GitHub.CommandPolicy

  describe "unsupported commands" do
    test "anything other than gh/git is denied" do
      assert {:deny, _} = CommandPolicy.classify("bash", ["-c", "true"])
      assert {:deny, _} = CommandPolicy.classify("curl", ["https://github.com"])
      assert {:deny, _} = CommandPolicy.classify("", [])
    end
  end

  describe "gh reads" do
    test "issue and pr reads are allowed" do
      assert :allow = CommandPolicy.classify("gh", ["issue", "list"])
      assert :allow = CommandPolicy.classify("gh", ["issue", "view", "42"])
      assert :allow = CommandPolicy.classify("gh", ["pr", "list", "--state", "open"])
      assert :allow = CommandPolicy.classify("gh", ["pr", "diff", "7"])
      assert :allow = CommandPolicy.classify("gh", ["pr", "checks", "7"])
    end

    test "repo view, runs, releases, search are allowed" do
      assert :allow = CommandPolicy.classify("gh", ["repo", "view"])
      assert :allow = CommandPolicy.classify("gh", ["run", "list"])
      assert :allow = CommandPolicy.classify("gh", ["run", "view", "123", "--log"])
      assert :allow = CommandPolicy.classify("gh", ["release", "list"])
      assert :allow = CommandPolicy.classify("gh", ["search", "issues", "crash"])
    end

    test "trailing flags do not affect subcommand detection" do
      assert :allow = CommandPolicy.classify("gh", ["issue", "list", "--repo", "o/r"])
      assert :allow = CommandPolicy.classify("gh", ["pr", "view", "7", "--json", "title"])
    end

    test "flag-led argv never silently allows — falls back to approval" do
      # `gh issue --repo o/r list` misparses the flag value as the
      # subcommand; the safe outcome is approval, not allow.
      assert {:approval, _} = CommandPolicy.classify("gh", ["issue", "--repo", "o/r", "list"])
    end
  end

  describe "gh working-loop mutations" do
    test "issue and pr lifecycle commands are allowed" do
      assert :allow = CommandPolicy.classify("gh", ["issue", "create", "--title", "t"])
      assert :allow = CommandPolicy.classify("gh", ["issue", "comment", "42", "--body", "hi"])
      assert :allow = CommandPolicy.classify("gh", ["issue", "close", "42"])
      assert :allow = CommandPolicy.classify("gh", ["pr", "create", "--fill"])
      assert :allow = CommandPolicy.classify("gh", ["pr", "comment", "7", "--body", "hi"])
      assert :allow = CommandPolicy.classify("gh", ["pr", "ready", "7"])
    end
  end

  describe "gh approval-gated commands" do
    test "pr merge requires approval" do
      assert {:approval, _} = CommandPolicy.classify("gh", ["pr", "merge", "7"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["pr", "merge", "7", "--squash"])
    end

    test "releases, workflows, repo settings require approval" do
      assert {:approval, _} = CommandPolicy.classify("gh", ["release", "create", "v1.0.0"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["release", "delete", "v1.0.0"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["workflow", "run", "ci.yml"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["repo", "edit", "--visibility", "public"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["repo", "archive"])
    end

    test "unknown command groups fall back to approval, not allow" do
      assert {:approval, _} = CommandPolicy.classify("gh", ["project", "create"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["gist", "create", "file.txt"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["ruleset", "list"])
    end
  end

  describe "gh denied commands" do
    test "repo delete is denied" do
      assert {:deny, _} = CommandPolicy.classify("gh", ["repo", "delete", "o/r", "--yes"])
    end

    test "secrets and variables are denied" do
      assert {:deny, _} = CommandPolicy.classify("gh", ["secret", "set", "KEY"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["secret", "list"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["variable", "set", "KEY"])
    end

    test "auth, config, alias, extension, codespace are denied" do
      assert {:deny, _} = CommandPolicy.classify("gh", ["auth", "token"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["auth", "login"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["config", "set", "key", "val"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["alias", "set", "x", "repo delete"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["extension", "install", "owner/ext"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["codespace", "create"])
      assert {:deny, _} = CommandPolicy.classify("gh", ["ssh-key", "add"])
    end

    test "empty gh command is denied" do
      assert {:deny, _} = CommandPolicy.classify("gh", [])
    end
  end

  describe "gh api" do
    test "default method with no body flags is allowed (GET)" do
      assert :allow = CommandPolicy.classify("gh", ["api", "repos/o/r/issues"])
      assert :allow = CommandPolicy.classify("gh", ["api", "repos/o/r/pulls", "--paginate"])
    end

    test "explicit GET/HEAD is allowed even with field flags (query params)" do
      assert :allow = CommandPolicy.classify("gh", ["api", "-X", "GET", "search/issues", "-f", "q=bug"])
      assert :allow = CommandPolicy.classify("gh", ["api", "--method", "HEAD", "repos/o/r"])
      assert :allow = CommandPolicy.classify("gh", ["api", "--method=GET", "repos/o/r", "-F", "per_page=100"])
    end

    test "body flags without explicit method imply POST and require approval" do
      assert {:approval, _} = CommandPolicy.classify("gh", ["api", "repos/o/r/issues", "-f", "title=x"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["api", "repos/o/r/labels", "--field", "name=bug"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["api", "repos/o/r/issues", "--input", "body.json"])
    end

    test "explicit mutating methods require approval" do
      assert {:approval, _} = CommandPolicy.classify("gh", ["api", "-X", "POST", "repos/o/r/issues"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["api", "-X", "DELETE", "repos/o/r"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["api", "--method", "PATCH", "repos/o/r"])
      assert {:approval, _} = CommandPolicy.classify("gh", ["api", "--method=put", "repos/o/r/contents/f"])
    end
  end

  describe "git push" do
    test "pushing a feature branch is allowed" do
      assert :allow = CommandPolicy.classify("git", ["push", "origin", "fix/issue-42"])
      assert :allow = CommandPolicy.classify("git", ["push", "--force", "origin", "fix/issue-42"])
      assert :allow = CommandPolicy.classify("git", ["push", "origin", "HEAD:fix/issue-42"])
      assert :allow = CommandPolicy.classify("git", ["push", "-u", "origin", "feature-x"])
    end

    test "pushing to protected branches is denied" do
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "origin", "main"])
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "origin", "master"])
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "origin", "HEAD:main"])
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "origin", "feature:refs/heads/main"])
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "--force", "origin", "+main"])
    end

    test "deleting a protected branch is denied, feature branch deletion allowed" do
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "origin", ":main"])
      assert :allow = CommandPolicy.classify("git", ["push", "origin", ":old-feature"])
    end

    test "custom protected branch list is honored" do
      opts = [protected_branches: ["develop"]]
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "origin", "develop"], opts)
      assert :allow = CommandPolicy.classify("git", ["push", "origin", "main"], opts)
    end

    test "push without explicit remote and branch is denied" do
      assert {:deny, _} = CommandPolicy.classify("git", ["push"])
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "origin"])
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "--force", "origin"])
    end

    test "mirror and all pushes are denied, tags need approval" do
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "--mirror", "origin"])
      assert {:deny, _} = CommandPolicy.classify("git", ["push", "--all", "origin"])
      assert {:approval, _} = CommandPolicy.classify("git", ["push", "--tags", "origin", "v1"])
    end
  end

  describe "git non-push verbs" do
    test "fetch, pull, ls-remote are allowed" do
      assert :allow = CommandPolicy.classify("git", ["fetch", "origin"])
      assert :allow = CommandPolicy.classify("git", ["pull", "origin", "main"])
      assert :allow = CommandPolicy.classify("git", ["ls-remote", "origin"])
    end

    test "local git verbs are denied (agent runs them via Bash)" do
      assert {:deny, _} = CommandPolicy.classify("git", ["commit", "-m", "x"])
      assert {:deny, _} = CommandPolicy.classify("git", ["checkout", "-b", "branch"])
      assert {:deny, _} = CommandPolicy.classify("git", ["rebase", "main"])
      assert {:deny, _} = CommandPolicy.classify("git", [])
    end
  end
end
