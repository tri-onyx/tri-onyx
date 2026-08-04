defmodule TriOnyx.Connectors.GitHubTest do
  # Mutates the :github app env — must not run async with other tests.
  use ExUnit.Case, async: false

  alias TriOnyx.Connectors.GitHub

  setup do
    original = Application.get_env(:tri_onyx, :github)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tri_onyx, :github)
        value -> Application.put_env(:tri_onyx, :github, value)
      end
    end)

    :ok
  end

  describe "token_for/1" do
    test "returns the repo-specific token when configured" do
      Application.put_env(:tri_onyx, :github,
        tokens: %{"o/r" => "pat-specific", "default" => "pat-default"}
      )

      assert {:ok, "pat-specific"} = GitHub.token_for("o/r")
    end

    test "falls back to the default token" do
      Application.put_env(:tri_onyx, :github,
        tokens: %{"o/r" => "pat-specific", "default" => "pat-default"}
      )

      assert {:ok, "pat-default"} = GitHub.token_for("other/repo")
    end

    test "errors when neither repo token nor default is configured" do
      Application.put_env(:tri_onyx, :github, tokens: %{"o/r" => "pat-specific"})

      assert {:error, message} = GitHub.token_for("other/repo")
      assert message =~ "other/repo"
      assert message =~ "default"
    end

    test "errors when github is not configured at all" do
      Application.delete_env(:tri_onyx, :github)

      assert {:error, _} = GitHub.token_for("o/r")
    end

    test "empty token strings do not count" do
      Application.put_env(:tri_onyx, :github, tokens: %{"o/r" => "", "default" => ""})

      assert {:error, _} = GitHub.token_for("o/r")
    end
  end

  describe "repo_dir/1" do
    test "builds the clone path under the workspace data dir" do
      assert GitHub.repo_dir("o/r") =~ ~r"/data/github/o/r\z"
    end
  end
end
