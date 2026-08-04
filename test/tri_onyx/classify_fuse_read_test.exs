defmodule TriOnyx.ClassifyReadableReposTest do
  use ExUnit.Case, async: false

  alias TriOnyx.AgentDefinition
  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskManifest

  setup do
    RiskManifest.clear()
    on_exit(fn -> RiskManifest.clear() end)
    :ok
  end

  defp make_def(name, repos_read \\ [], repos_write \\ []) do
    %AgentDefinition{
      name: name,
      tools: ["Read"],
      system_prompt: "test",
      repos_read: repos_read,
      repos_write: repos_write
    }
  end

  test "session read floor is the max labels across readable repos" do
    RiskManifest.put("news", ["agents/news/digest.md"], :high, :medium)

    # The agent's own repo taints its floor
    assert %{taint: :high, sensitivity: :medium, reason: reason} =
             InformationClassifier.classify_readable_repos(make_def("news"))

    assert reason =~ "agents/news"
  end

  test "repos_read grants pull in other repos' labels" do
    RiskManifest.put("wiki", ["shared/knowledge/index.md"], :medium, :low)

    assert %{taint: :medium} =
             InformationClassifier.classify_readable_repos(make_def("clean", ["knowledge"]))
  end

  test "labels in unrelated repos do not taint the session" do
    RiskManifest.put("news", ["agents/news/digest.md"], :high, :high)

    assert %{taint: :low, sensitivity: :low} =
             InformationClassifier.classify_readable_repos(make_def("loner"))
  end

  test "empty manifest yields a low floor" do
    assert %{taint: :low, sensitivity: :low} =
             InformationClassifier.classify_readable_repos(make_def("anyone", ["core"]))
  end
end
