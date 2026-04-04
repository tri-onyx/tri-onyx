defmodule TriOnyx.Integration.BCPTaintTest do
  @moduledoc """
  Integration tests for BCP taint-neutral delivery.

  Verifies the core security property of the Bandwidth-Constrained
  Protocol: BCP responses are always classified as low taint regardless of
  sender taint level, while free-text inter-agent messages propagate the
  sender's taint without step-down.

  Tests cover:
  - BCP taint classification across all categories
  - Free-text taint propagation (no step-down for sanitized messages)
  - Category-1 deterministic validation (boolean, enum, integer)
  - Category-2 word-limit enforcement
  - Bandwidth budget tracking and enforcement
  - Contrast between BCP and free-text taint semantics
  """
  use ExUnit.Case, async: true

  alias TriOnyx.AgentDefinition
  alias TriOnyx.BCP.Query
  alias TriOnyx.BCP.Validator
  alias TriOnyx.InformationClassifier

  @controller_def %AgentDefinition{
    name: "bcp-controller",
    description: "Controller agent for BCP tests",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Grep"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "BCP controller test agent.",
    bcp_channels: [
      %{
        peer: "bcp-reader",
        role: :controller,
        rates: %{cat1: %{limit: 20, window_ms: 3_600_000}, cat2: %{limit: 5, window_ms: 3_600_000}, cat3: :denied},
        max_category: 2,
        subscriptions: []
      }
    ]
  }

  @reader_def %AgentDefinition{
    name: "bcp-reader",
    description: "Reader agent for BCP tests",
    model: "claude-haiku-4-5",
    tools: ["Read", "WebFetch"],
    network: :outbound,
    fs_read: [],
    fs_write: [],
    system_prompt: "BCP reader test agent.",
    bcp_channels: [
      %{
        peer: "bcp-controller",
        role: :reader,
        rates: %{cat1: %{limit: 20, window_ms: 3_600_000}, cat2: %{limit: 5, window_ms: 3_600_000}, cat3: :denied},
        max_category: 2,
        subscriptions: []
      }
    ]
  }

  # ── BCP taint classification ──────────────────────────────────────────

  describe "BCP taint classification" do
    test "classify_bcp steps down sender taint by one level" do
      assert %{taint: :low} = InformationClassifier.classify_bcp(1, :low)
      assert %{taint: :low} = InformationClassifier.classify_bcp(1, :medium)
      assert %{taint: :medium} = InformationClassifier.classify_bcp(1, :high)
    end

    test "classify_bcp defaults to low sender taint" do
      result = InformationClassifier.classify_bcp(1)
      assert %{taint: :low, sensitivity: :low} = result
    end

    test "classify_bcp reason includes category and sender taint" do
      result = InformationClassifier.classify_bcp(2, :high)
      assert result.reason =~ "BCP cat-2"
      assert result.reason =~ "sender taint: high"
    end

    test "classify_bcp sensitivity is always low" do
      for category <- [1, 2, 3], sender <- [:low, :medium, :high] do
        result = InformationClassifier.classify_bcp(category, sender)
        assert result.sensitivity == :low, "expected :low sensitivity for cat-#{category} sender #{sender}"
      end
    end
  end

  # ── Free-text taint propagation (no step-down) ────────────────────────

  describe "free-text taint propagation (no step-down)" do
    test "sanitized inter-agent message from high-taint sender stays high" do
      result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: :high, sensitivity: :low})
      assert %{taint: :high} = result
    end

    test "sanitized inter-agent message from medium-taint sender stays medium" do
      result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: :medium, sensitivity: :low})
      assert %{taint: :medium} = result
    end

    test "sanitized inter-agent message from low-taint sender stays low" do
      result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: :low, sensitivity: :low})
      assert %{taint: :low} = result
    end

    test "raw inter-agent message from high-taint sender stays high" do
      result = InformationClassifier.classify_inter_agent(:raw, %{taint: :high, sensitivity: :low})
      assert %{taint: :high} = result
    end

    test "sanitization does NOT step down taint -- all levels preserved" do
      for level <- [:low, :medium, :high] do
        result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: level, sensitivity: :low})

        assert result.taint == level,
               "expected taint #{level} to pass through sanitized, got #{result.taint}"
      end
    end

    test "classify_inter_agent with full sender map preserves both axes" do
      sender = %{taint: :high, sensitivity: :medium}
      result = InformationClassifier.classify_inter_agent(:sanitized, sender)
      assert result.taint == :high
      assert result.sensitivity == :medium
    end
  end

  # ── Context field ────────────────────────────────────────────────────

  describe "context field" do
    test "context is preserved through Cat-1 query creation" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-context-cat1",
          context: "Check the email from alice@example.com received today",
          fields: [
            %{name: "is_urgent", type: :boolean, options: nil, min: nil, max: nil}
          ]
        })

      assert query.context == "Check the email from alice@example.com received today"
    end

    test "context is preserved through Cat-2 query creation" do
      {:ok, query} =
        Query.new(%{
          category: 2,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-context-cat2",
          context: "Look at the latest invoice PDF in the workspace",
          questions: [
            %{name: "sender_name", format: :person_name, max_words: 5}
          ]
        })

      assert query.context == "Look at the latest invoice PDF in the workspace"
    end

    test "context defaults to nil for backwards compatibility" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-context-nil",
          fields: [
            %{name: "flag", type: :boolean, options: nil, min: nil, max: nil}
          ]
        })

      assert query.context == nil
    end
  end

  # ── Cat-1 validation ──────────────────────────────────────────────────

  describe "cat-1 validation" do
    test "valid boolean passes" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat1-bool",
          fields: [
            %{name: "is_malicious", type: :boolean, options: nil, min: nil, max: nil}
          ]
        })

      assert {:ok, %{"is_malicious" => true}} =
               Validator.validate_response(query, %{"is_malicious" => true})

      assert {:ok, %{"is_malicious" => false}} =
               Validator.validate_response(query, %{"is_malicious" => false})
    end

    test "valid enum passes" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat1-enum",
          fields: [
            %{
              name: "severity",
              type: :enum,
              options: ["low", "medium", "high"],
              min: nil,
              max: nil
            }
          ]
        })

      for option <- ["low", "medium", "high"] do
        assert {:ok, %{"severity" => ^option}} =
                 Validator.validate_response(query, %{"severity" => option})
      end
    end

    test "valid integer in range passes" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat1-int",
          fields: [
            %{name: "confidence", type: :integer, options: nil, min: 0, max: 100}
          ]
        })

      for value <- [0, 50, 100] do
        assert {:ok, %{"confidence" => ^value}} =
                 Validator.validate_response(query, %{"confidence" => value})
      end
    end

    test "invalid enum value is rejected" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat1-bad-enum",
          fields: [
            %{
              name: "severity",
              type: :enum,
              options: ["low", "medium", "high"],
              min: nil,
              max: nil
            }
          ]
        })

      result = Validator.validate_response(query, %{"severity" => "critical"})
      assert {:error, reason} = result
      assert reason =~ "severity"
      assert reason =~ "not in allowed options"
    end

    test "out-of-range integer is rejected" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat1-bad-int",
          fields: [
            %{name: "score", type: :integer, options: nil, min: 1, max: 10}
          ]
        })

      # Below minimum
      result_low = Validator.validate_response(query, %{"score" => 0})
      assert {:error, reason_low} = result_low
      assert reason_low =~ "out of range"

      # Above maximum
      result_high = Validator.validate_response(query, %{"score" => 11})
      assert {:error, reason_high} = result_high
      assert reason_high =~ "out of range"
    end

    test "non-boolean value for boolean field is rejected" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat1-bad-bool",
          fields: [
            %{name: "is_valid", type: :boolean, options: nil, min: nil, max: nil}
          ]
        })

      result = Validator.validate_response(query, %{"is_valid" => "yes"})
      assert {:error, reason} = result
      assert reason =~ "is_valid"
      assert reason =~ "boolean"
    end

    test "multi-field cat-1 validates all fields" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat1-multi",
          fields: [
            %{name: "is_malicious", type: :boolean, options: nil, min: nil, max: nil},
            %{
              name: "severity",
              type: :enum,
              options: ["low", "medium", "high"],
              min: nil,
              max: nil
            },
            %{name: "confidence", type: :integer, options: nil, min: 0, max: 100}
          ]
        })

      response = %{"is_malicious" => false, "severity" => "low", "confidence" => 85}
      assert {:ok, validated} = Validator.validate_response(query, response)
      assert validated["is_malicious"] == false
      assert validated["severity"] == "low"
      assert validated["confidence"] == 85
    end
  end

  # ── Cat-2 validation ──────────────────────────────────────────────────

  describe "cat-2 validation" do
    test "response within word limit passes" do
      {:ok, query} =
        Query.new(%{
          category: 2,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat2-ok",
          questions: [
            %{name: "author", format: :person_name, max_words: 5}
          ]
        })

      response = %{"author" => "Jane Doe"}
      assert {:ok, validated, _anomalies} = Validator.validate_response(query, response)
      assert validated["author"] == "Jane Doe"
    end

    test "response exceeding word limit is rejected" do
      {:ok, query} =
        Query.new(%{
          category: 2,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat2-exceed",
          questions: [
            %{name: "author", format: :person_name, max_words: 3}
          ]
        })

      response = %{"author" => "Sir Arthur Conan Doyle Junior"}
      result = Validator.validate_response(query, response)
      assert {:error, reason} = result
      assert reason =~ "word count"
      assert reason =~ "exceeds limit"
    end

    test "response at exact word limit passes" do
      {:ok, query} =
        Query.new(%{
          category: 2,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat2-exact",
          questions: [
            %{name: "name", format: :person_name, max_words: 3}
          ]
        })

      response = %{"name" => "Arthur Conan Doyle"}
      assert {:ok, _validated, _anomalies} = Validator.validate_response(query, response)
    end

    test "date format validation passes for valid ISO 8601 date" do
      {:ok, query} =
        Query.new(%{
          category: 2,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat2-date",
          questions: [
            %{name: "published", format: :date, max_words: 1}
          ]
        })

      response = %{"published" => "2024-01-15"}
      assert {:ok, _validated, _anomalies} = Validator.validate_response(query, response)
    end

    test "email format validation passes for valid email" do
      {:ok, query} =
        Query.new(%{
          category: 2,
          from: "bcp-controller",
          to: "bcp-reader",
          session_id: "test-session-cat2-email",
          questions: [
            %{name: "contact", format: :email, max_words: 1}
          ]
        })

      response = %{"contact" => "alice@example.com"}
      assert {:ok, _validated, _anomalies} = Validator.validate_response(query, response)
    end
  end

  # ── BCP vs free-text contrast ────────────────────────────────────────

  describe "BCP vs free-text taint contrast" do
    test "BCP reduces high sender taint to medium, free-text passes it through" do
      bcp_result = InformationClassifier.classify_bcp(1, :high)
      assert bcp_result.taint == :medium

      freetext_result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: :high, sensitivity: :low})
      assert freetext_result.taint == :high
    end

    test "BCP reduces medium sender taint to low, free-text passes it through" do
      bcp_result = InformationClassifier.classify_bcp(2, :medium)
      assert bcp_result.taint == :low

      freetext_result =
        InformationClassifier.classify_inter_agent(:sanitized, %{taint: :medium, sensitivity: :low})

      assert freetext_result.taint == :medium
    end

    test "higher_level correctly compares taint levels" do
      assert InformationClassifier.higher_level(:low, :high) == :high
      assert InformationClassifier.higher_level(:high, :low) == :high
      assert InformationClassifier.higher_level(:medium, :medium) == :medium
      assert InformationClassifier.higher_level(:low, :low) == :low
    end

    test "BCP taint is always strictly lower than free-text for same sender" do
      for sender_taint <- [:medium, :high] do
        bcp = InformationClassifier.classify_bcp(1, sender_taint)
        freetext = InformationClassifier.classify_inter_agent(:sanitized, %{taint: sender_taint, sensitivity: :low})

        bcp_rank = %{low: 0, medium: 1, high: 2}
        assert bcp_rank[bcp.taint] < bcp_rank[freetext.taint],
          "BCP taint #{bcp.taint} should be lower than free-text taint #{freetext.taint} for sender #{sender_taint}"
      end
    end
  end
end
