defmodule TriOnyx.InformationClassifierTest do
  use ExUnit.Case, async: true

  alias TriOnyx.InformationClassifier

  describe "classify_trigger/1" do
    test "webhook trigger has high taint, low sensitivity" do
      result = InformationClassifier.classify_trigger(:webhook)
      assert %{taint: :high, sensitivity: :low, reason: reason} = result
      assert reason =~ "webhook"
    end

    test "connector_unverified trigger has high taint, medium sensitivity" do
      result = InformationClassifier.classify_trigger(:connector_unverified)
      assert %{taint: :high, sensitivity: :medium, reason: reason} = result
      assert reason =~ "unverified"
    end

    test "cron trigger has low taint and sensitivity" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:cron)
    end

    test "heartbeat trigger has low taint and sensitivity" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:heartbeat)
    end

    test "external_message trigger has low taint and sensitivity" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:external_message)
    end

    test "connector_verified trigger has low taint and sensitivity" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:connector_verified)
    end

    test "unknown trigger type has low taint and sensitivity" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:some_future_trigger)
    end
  end

  describe "classify_tool_result/2" do
    test "WebFetch result has high taint" do
      result = InformationClassifier.classify_tool_result("WebFetch", %{"url" => "https://example.com"})
      assert %{taint: :high, sensitivity: :low, reason: reason} = result
      assert reason =~ "WebFetch"
      assert reason =~ "external data"
    end

    test "WebSearch result has high taint" do
      result = InformationClassifier.classify_tool_result("WebSearch", %{"query" => "test"})
      assert %{taint: :high, reason: reason} = result
      assert reason =~ "WebSearch"
    end

    test "Read from /workspace path has low taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/workspace/src/main.py"})
      assert %{taint: :low, sensitivity: :low, reason: reason} = result
      assert reason =~ "controlled path"
    end

    test "Read from /mnt/host path has low taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/mnt/host/project/file.txt"})
      assert %{taint: :low} = result
    end

    test "Read from relative path has low taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "src/main.py"})
      assert %{taint: :low} = result
    end

    test "Read from ./ relative path has low taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "./config.yaml"})
      assert %{taint: :low} = result
    end

    test "Read from external absolute path has high taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/tmp/uploaded_file.txt"})
      assert %{taint: :high, reason: reason} = result
      assert reason =~ "external path"
    end

    test "Read from /etc path has high taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/etc/passwd"})
      assert %{taint: :high} = result
    end

    test "Read from /home path has high taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/home/user/data.txt"})
      assert %{taint: :high} = result
    end

    test "Read with missing file_path has high taint (external by default)" do
      result = InformationClassifier.classify_tool_result("Read", %{})
      assert %{taint: :high} = result
    end

    # Path traversal tests
    test "Read with relative traversal out of workspace has high taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "../../etc/passwd"})
      assert %{taint: :high} = result
    end

    test "Read with absolute traversal out of workspace has high taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/workspace/../etc/passwd"})
      assert %{taint: :high} = result
    end

    test "Read with traversal staying within workspace has low taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/workspace/sub/../other/file.py"})
      assert %{taint: :low} = result
    end

    test "Grep result has low taint" do
      result = InformationClassifier.classify_tool_result("Grep", %{"pattern" => "foo"})
      assert %{taint: :low} = result
    end

    test "Glob result has low taint" do
      result = InformationClassifier.classify_tool_result("Glob", %{"pattern" => "*.ex"})
      assert %{taint: :low} = result
    end

    test "Write result has low taint" do
      result = InformationClassifier.classify_tool_result("Write", %{"file_path" => "/workspace/out.txt"})
      assert %{taint: :low} = result
    end

    test "Bash result has low taint (no-network default)" do
      result = InformationClassifier.classify_tool_result("Bash", %{"command" => "ls"})
      assert %{taint: :low} = result
    end

    test "SendMessage result has low taint" do
      result = InformationClassifier.classify_tool_result("SendMessage", %{})
      assert %{taint: :low, reason: reason} = result
      assert reason =~ "SendMessage"
    end

    test "SendEmail result has low taint with descriptive reason" do
      result = InformationClassifier.classify_tool_result("SendEmail", %{})
      assert %{taint: :low, reason: reason} = result
      assert reason =~ "SendEmail"
      assert reason =~ "SMTP"
    end

    test "MoveEmail result has low taint with descriptive reason" do
      result = InformationClassifier.classify_tool_result("MoveEmail", %{})
      assert %{taint: :low, reason: reason} = result
      assert reason =~ "MoveEmail"
    end

    test "CreateFolder result has low taint with descriptive reason" do
      result = InformationClassifier.classify_tool_result("CreateFolder", %{})
      assert %{taint: :low, reason: reason} = result
      assert reason =~ "CreateFolder"
    end
  end

  describe "classify_tool_result/3 with sensitivity metadata (custom tools)" do
    # These tests verify the metadata fallback path for custom tools not in SensitivityMatrix.
    # Known built-in tools use SensitivityMatrix directly, ignoring the metadata argument.

    test "custom tool requiring auth gets medium sensitivity" do
      meta = %{requires_auth: true, data_sensitivity: :low}
      result = InformationClassifier.classify_tool_result("ExternalAPITool", %{}, meta)
      assert %{sensitivity: :medium} = result
    end

    test "custom tool requiring auth with high sensitivity gets high sensitivity" do
      meta = %{requires_auth: true, data_sensitivity: :high}
      result = InformationClassifier.classify_tool_result("ExternalAPITool", %{}, meta)
      assert %{sensitivity: :high} = result
    end

    test "custom tool without auth stays low sensitivity" do
      meta = %{requires_auth: false, data_sensitivity: :low}
      result = InformationClassifier.classify_tool_result("ExternalAPITool", %{}, meta)
      assert %{sensitivity: :low} = result
    end

    test "known built-in tool ignores metadata — Read stays low sensitivity regardless of meta" do
      meta = %{requires_auth: true, data_sensitivity: :high}
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/workspace/x"}, meta)
      assert %{taint: :low, sensitivity: :low} = result
    end
  end

  describe "classify_inter_agent/2 with classification maps" do
    test "sanitized message passes through sender taint, passes sensitivity" do
      sender = %{taint: :high, sensitivity: :medium}
      result = InformationClassifier.classify_inter_agent(:sanitized, sender)
      assert %{taint: :high, sensitivity: :medium, reason: reason} = result
      assert reason =~ "sanitized"
    end

    test "raw message inherits both axes from sender" do
      sender = %{taint: :high, sensitivity: :high}
      result = InformationClassifier.classify_inter_agent(:raw, sender)
      assert %{taint: :high, sensitivity: :high} = result
    end

    test "sanitized message from low taint stays low, sensitivity passes through" do
      sender = %{taint: :low, sensitivity: :high}
      result = InformationClassifier.classify_inter_agent(:sanitized, sender)
      assert %{taint: :low, sensitivity: :high} = result
    end
  end

  describe "classify_inter_agent/2 with taint-only sender (sensitivity defaults to low)" do
    test "sanitized message from high-taint sender stays high" do
      result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: :high, sensitivity: :low})
      assert %{taint: :high, sensitivity: :low} = result
    end

    test "sanitized message from medium-taint sender stays medium" do
      result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: :medium, sensitivity: :low})
      assert %{taint: :medium, sensitivity: :low} = result
    end

    test "raw message from high-taint sender inherits high" do
      result = InformationClassifier.classify_inter_agent(:raw, %{taint: :high, sensitivity: :low})
      assert %{taint: :high, sensitivity: :low} = result
    end
  end

  describe "higher_levels/2" do
    test "takes element-wise max of two classification maps" do
      a = %{taint: :low, sensitivity: :high, reason: "a"}
      b = %{taint: :high, sensitivity: :low, reason: "b"}
      result = InformationClassifier.higher_levels(a, b)
      assert %{taint: :high, sensitivity: :high} = result
    end

    test "returns same when both are equal" do
      a = %{taint: :medium, sensitivity: :medium, reason: "a"}
      b = %{taint: :medium, sensitivity: :medium, reason: "b"}
      result = InformationClassifier.higher_levels(a, b)
      assert %{taint: :medium, sensitivity: :medium} = result
    end
  end

  describe "classify_tool_sensitivity/2" do
    # Known tools use SensitivityMatrix; unknown tools fall back to metadata.

    test "known tool returns matrix value regardless of meta" do
      assert :low = InformationClassifier.classify_tool_sensitivity("Read", %{requires_auth: true, data_sensitivity: :high})
      assert :medium = InformationClassifier.classify_tool_sensitivity("SendEmail", %{})
      assert :medium = InformationClassifier.classify_tool_sensitivity("MoveEmail", %{})
    end

    test "unknown tool: no auth returns low" do
      assert :low = InformationClassifier.classify_tool_sensitivity("ExternalAPITool", %{requires_auth: false, data_sensitivity: :low})
    end

    test "unknown tool: auth required returns medium" do
      assert :medium = InformationClassifier.classify_tool_sensitivity("ExternalAPITool", %{requires_auth: true, data_sensitivity: :low})
    end

    test "unknown tool: auth required with high sensitivity returns high" do
      assert :high = InformationClassifier.classify_tool_sensitivity("ExternalAPITool", %{requires_auth: true, data_sensitivity: :high})
    end

    test "unknown tool defaults to low for empty meta" do
      assert :low = InformationClassifier.classify_tool_sensitivity("ExternalAPITool", %{})
    end
  end

  describe "higher_level/2" do
    test "returns higher of two levels" do
      assert :high = InformationClassifier.higher_level(:high, :low)
      assert :high = InformationClassifier.higher_level(:low, :high)
      assert :medium = InformationClassifier.higher_level(:medium, :low)
      assert :medium = InformationClassifier.higher_level(:low, :medium)
      assert :high = InformationClassifier.higher_level(:high, :medium)
    end

    test "returns same level when equal" do
      assert :low = InformationClassifier.higher_level(:low, :low)
      assert :medium = InformationClassifier.higher_level(:medium, :medium)
      assert :high = InformationClassifier.higher_level(:high, :high)
    end
  end

  describe "step_down/1" do
    test "high steps down to medium" do
      assert :medium = InformationClassifier.step_down(:high)
    end

    test "medium steps down to low" do
      assert :low = InformationClassifier.step_down(:medium)
    end

    test "low stays low" do
      assert :low = InformationClassifier.step_down(:low)
    end
  end

  describe "elevating?/1" do
    test "high is elevating" do
      assert InformationClassifier.elevating?(:high)
    end

    test "medium is elevating" do
      assert InformationClassifier.elevating?(:medium)
    end

    test "low is not elevating" do
      refute InformationClassifier.elevating?(:low)
    end
  end
end
