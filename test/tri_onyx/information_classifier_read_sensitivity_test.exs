defmodule TriOnyx.InformationClassifierReadSensitivityTest do
  use ExUnit.Case, async: false

  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskManifest

  @agent "ic-read-sens-agent"

  setup do
    :ok =
      RiskManifest.put(@agent, ["agents/#{@agent}/secret.md", "shared/vault/key.md"], :low, :high)

    :ok
  end

  defp read_sensitivity(path) do
    InformationClassifier.classify_tool_result("Read", %{"file_path" => path}, %{agent_name: @agent}).sensitivity
  end

  test "plain paths resolve to the manifest sensitivity (control)" do
    assert read_sensitivity("/workspace/secret.md") == :high
    assert read_sensitivity("/repos/vault/key.md") == :high
  end

  test "non-normalized paths cannot dodge the sensitivity lookup" do
    for path <- [
          "/workspace/sub/../secret.md",
          "/workspace/./secret.md",
          "/workspace//secret.md",
          "sub/../secret.md",
          "./secret.md",
          "/workspace/../repos/vault/key.md",
          "/repos/vault/x/../key.md"
        ] do
      assert read_sensitivity(path) == :high,
             "Read of #{inspect(path)} reaches a high-sensitivity file but was classified " <>
               "#{read_sensitivity(path)}; paths must be normalized before the manifest lookup"
    end
  end
end
