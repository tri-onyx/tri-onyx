defmodule TriOnyx.Integration.BCTPTaintTest do
  @moduledoc """
  Integration tests for BCTP taint-neutral delivery.

  Verifies the core security property of the Bandwidth-Constrained Trust
  Protocol: BCTP responses are always classified as low taint regardless of
  sender taint level, while free-text inter-agent messages propagate the
  sender's taint without step-down.

  Tests cover:
  - BCTP taint classification across all categories
  - Free-text taint propagation (no step-down for sanitized messages)
  - Category-1 deterministic validation (boolean, enum, integer)
  - Category-2 word-limit enforcement
  - Bandwidth budget tracking and enforcement
  - Contrast between BCTP and free-text taint semantics
  """
  use ExUnit.Case, async: true

  alias TriOnyx.AgentDefinition
  alias TriOnyx.BCTP.Bandwidth
  alias TriOnyx.BCTP.Query
  alias TriOnyx.BCTP.Validator
  alias TriOnyx.InformationClassifier

  @controller_def %AgentDefinition{
    name: "bctp-controller",
    description: "Controller agent for BCTP tests",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Grep"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "BCTP controller test agent.",
    bctp_channels: [
      %{
        peer: "bctp-reader",
        role: :controller,
        max_category: 2,
        budget_bits: 100.0,
        max_cat2_queries: 5,
        max_cat3_queries: 0
      }
    ]
  }

  @reader_def %AgentDefinition{
    name: "bctp-reader",
    description: "Reader agent for BCTP tests",
    model: "claude-haiku-4-5",
    tools: ["Read", "WebFetch"],
    network: :outbound,
    fs_read: [],
    fs_write: [],
    system_prompt: "BCTP reader test agent.",
    bctp_channels: [
      %{
        peer: "bctp-controller",
        role: :reader,
        max_category: 2,
        budget_bits: 100.0,
        max_cat2_queries: 5,
        max_cat3_queries: 0
      }
    ]
  }

  # ── BCTP taint classification ──────────────────────────────────────────

  describe "BCTP taint classification" do
    test "classify_bctp steps down sender taint by one level" do
      assert %{taint: :low} = InformationClassifier.classify_bctp(1, 3.0, :low)
      assert %{taint: :low} = InformationClassifier.classify_bctp(1, 3.0, :medium)
      assert %{taint: :medium} = InformationClassifier.classify_bctp(1, 3.0, :high)
    end

    test "classify_bctp defaults to low sender taint (backward compat)" do
      result = InformationClassifier.classify_bctp(1, 3.0)
      assert %{taint: :low, sensitivity: :low} = result
    end

    test "classify_bctp reason includes category and sender taint" do
      result = InformationClassifier.classify_bctp(2, 55.0, :high)
      assert result.reason =~ "BCTP cat-2"
      assert result.reason =~ "sender taint: high"
    end

    test "classify_bctp includes bandwidth bits in reason" do
      result = InformationClassifier.classify_bctp(1, 7.5)
      assert result.reason =~ "7.5 bits"
    end

    test "classify_bctp sensitivity is always low" do
      for category <- [1, 2, 3], sender <- [:low, :medium, :high] do
        result = InformationClassifier.classify_bctp(category, 100.0, sender)
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

  # ── Cat-1 validation ──────────────────────────────────────────────────

  describe "cat-1 validation" do
    test "valid boolean passes" do
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
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
          from: "bctp-controller",
          to: "bctp-reader",
          session_id: "test-session-cat2-email",
          questions: [
            %{name: "contact", format: :email, max_words: 1}
          ]
        })

      response = %{"contact" => "alice@example.com"}
      assert {:ok, _validated, _anomalies} = Validator.validate_response(query, response)
    end
  end

  # ── Bandwidth budget ──────────────────────────────────────────────────

  describe "bandwidth budget" do
    test "Bandwidth.new/1 creates budget from map" do
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 100.0,
          max_cat2_queries: 5,
          max_cat3_queries: 2
        })

      assert budget.max_bits_per_session == 100.0
      assert budget.max_cat2_queries == 5
      assert budget.max_cat3_queries == 2
      assert budget.used_bits == 0.0
    end

    test "Bandwidth.remaining/1 returns full budget when unused" do
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 100.0,
          max_cat2_queries: 5,
          max_cat3_queries: 2
        })

      assert Bandwidth.remaining(budget) == 100.0
    end

    test "Bandwidth.charge/2 deducts from budget and tracks remaining" do
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 100.0,
          max_cat2_queries: 5,
          max_cat3_queries: 2
        })

      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bctp-controller",
          to: "bctp-reader",
          session_id: "test-session-bw-charge",
          fields: [
            %{name: "flag", type: :boolean, options: nil, min: nil, max: nil}
          ]
        })

      # Boolean field costs 1 bit
      assert {:ok, updated} = Bandwidth.charge(budget, query)
      assert Bandwidth.remaining(updated) < 100.0
      assert updated.used_bits > 0.0
    end

    test "Bandwidth.charge/2 rejects when budget exceeded" do
      # Create a very small budget (2 bits total)
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 2.0,
          max_cat2_queries: 5,
          max_cat3_queries: 2
        })

      # 8 options = log2(8) = 3 bits, which exceeds 2-bit budget
      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bctp-controller",
          to: "bctp-reader",
          session_id: "test-session-bw-exceed",
          fields: [
            %{
              name: "color",
              type: :enum,
              options: [
                "red",
                "orange",
                "yellow",
                "green",
                "blue",
                "indigo",
                "violet",
                "black"
              ],
              min: nil,
              max: nil
            }
          ]
        })

      assert {:error, :budget_exceeded} = Bandwidth.charge(budget, query)
    end

    test "Bandwidth.charge/2 rejects when cat2 query limit exceeded" do
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 10_000.0,
          max_cat2_queries: 1,
          max_cat3_queries: 2
        })

      {:ok, query} =
        Query.new(%{
          category: 2,
          from: "bctp-controller",
          to: "bctp-reader",
          session_id: "test-session-bw-cat2",
          questions: [
            %{name: "name", format: :short_text, max_words: 3}
          ]
        })

      # First charge succeeds
      assert {:ok, updated} = Bandwidth.charge(budget, query)
      # Second charge hits cat2 limit
      assert {:error, :cat2_limit} = Bandwidth.charge(updated, query)
    end

    test "Bandwidth.charge/2 rejects when cat3 query limit exceeded" do
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 10_000.0,
          max_cat2_queries: 5,
          max_cat3_queries: 1
        })

      {:ok, query} =
        Query.new(%{
          category: 3,
          from: "bctp-controller",
          to: "bctp-reader",
          session_id: "test-session-bw-cat3",
          directive: "Summarize the document",
          max_words: 20
        })

      # First charge succeeds
      assert {:ok, updated} = Bandwidth.charge(budget, query)
      # Second charge hits cat3 limit
      assert {:error, :cat3_limit} = Bandwidth.charge(updated, query)
    end

    test "budget tracks cumulative usage across multiple queries" do
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 50.0,
          max_cat2_queries: 10,
          max_cat3_queries: 5
        })

      {:ok, query} =
        Query.new(%{
          category: 1,
          from: "bctp-controller",
          to: "bctp-reader",
          session_id: "test-session-bw-cumul",
          fields: [
            %{name: "flag", type: :boolean, options: nil, min: nil, max: nil}
          ]
        })

      # Charge multiple times, remaining should decrease each time
      {:ok, b1} = Bandwidth.charge(budget, query)
      {:ok, b2} = Bandwidth.charge(b1, query)
      {:ok, b3} = Bandwidth.charge(b2, query)

      assert Bandwidth.remaining(b1) > Bandwidth.remaining(b2)
      assert Bandwidth.remaining(b2) > Bandwidth.remaining(b3)
      assert b3.used_bits == b1.used_bits * 3
    end
  end

  # ── BCTP vs free-text contrast ────────────────────────────────────────

  describe "BCTP vs free-text taint contrast" do
    test "BCTP reduces high sender taint to medium, free-text passes it through" do
      bctp_result = InformationClassifier.classify_bctp(1, 3.0, :high)
      assert bctp_result.taint == :medium

      freetext_result = InformationClassifier.classify_inter_agent(:sanitized, %{taint: :high, sensitivity: :low})
      assert freetext_result.taint == :high
    end

    test "BCTP reduces medium sender taint to low, free-text passes it through" do
      bctp_result = InformationClassifier.classify_bctp(2, 55.0, :medium)
      assert bctp_result.taint == :low

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

    test "BCTP taint is always strictly lower than free-text for same sender" do
      for sender_taint <- [:medium, :high] do
        bctp = InformationClassifier.classify_bctp(1, 1.0, sender_taint)
        freetext = InformationClassifier.classify_inter_agent(:sanitized, %{taint: sender_taint, sensitivity: :low})

        bctp_rank = %{low: 0, medium: 1, high: 2}
        assert bctp_rank[bctp.taint] < bctp_rank[freetext.taint],
          "BCTP taint #{bctp.taint} should be lower than free-text taint #{freetext.taint} for sender #{sender_taint}"
      end
    end
  end
end
