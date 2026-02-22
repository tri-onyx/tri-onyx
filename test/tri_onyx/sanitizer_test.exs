defmodule TriOnyx.SanitizerTest do
  use ExUnit.Case

  alias TriOnyx.Sanitizer

  describe "sanitize/1" do
    test "accepts simple payload" do
      payload = %{"key" => "value", "count" => 42}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "accepts nested payload" do
      payload = %{"data" => %{"items" => [1, 2, 3], "active" => true}}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "accepts payload with nil values" do
      payload = %{"key" => nil}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "accepts empty payload" do
      assert {:ok, %{}} = Sanitizer.sanitize(%{})
    end

    test "accepts payload with booleans" do
      payload = %{"active" => true, "deleted" => false}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "accepts payload with numbers" do
      payload = %{"int" => 42, "float" => 3.14, "negative" => -1}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "rejects strings exceeding max length" do
      long_string = String.duplicate("x", 1025)
      payload = %{"data" => long_string}
      assert {:error, {:string_too_long, _detail}} = Sanitizer.sanitize(payload)
    end

    test "accepts strings at exactly max length" do
      max_string = String.duplicate("x", 1024)
      payload = %{"data" => max_string}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "rejects oversized strings in nested structures" do
      long_string = String.duplicate("x", 1025)
      payload = %{"nested" => %{"deep" => long_string}}
      assert {:error, {:string_too_long, detail}} = Sanitizer.sanitize(payload)
      assert detail =~ "$.nested.deep"
    end

    test "rejects oversized strings in lists" do
      long_string = String.duplicate("x", 1025)
      payload = %{"items" => [long_string]}
      assert {:error, {:string_too_long, detail}} = Sanitizer.sanitize(payload)
      assert detail =~ "$.items[0]"
    end

    test "rejects keys exceeding max length" do
      long_key = String.duplicate("k", 129)
      payload = %{long_key => "value"}
      assert {:error, {:key_too_long, _detail}} = Sanitizer.sanitize(payload)
    end

    test "accepts keys at exactly max length" do
      max_key = String.duplicate("k", 128)
      payload = %{max_key => "value"}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "rejects deeply nested structures" do
      # Build a structure 6 levels deep (exceeds max depth of 5)
      payload = %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => %{"f" => "too deep"}}}}}}
      assert {:error, {:depth_exceeded, _detail}} = Sanitizer.sanitize(payload)
    end

    test "accepts structures at max depth" do
      # 5 levels deep (at the limit)
      payload = %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => "ok"}}}}}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "rejects lists exceeding max length" do
      long_list = Enum.to_list(1..101)
      payload = %{"items" => long_list}
      assert {:error, {:list_too_long, _detail}} = Sanitizer.sanitize(payload)
    end

    test "accepts lists at exactly max length" do
      max_list = Enum.to_list(1..100)
      payload = %{"items" => max_list}
      assert {:ok, ^payload} = Sanitizer.sanitize(payload)
    end

    test "rejects maps with too many keys" do
      big_map =
        1..51
        |> Enum.map(fn i -> {"key_#{i}", i} end)
        |> Map.new()

      assert {:error, {:too_many_keys, _detail}} = Sanitizer.sanitize(big_map)
    end

    test "rejects non-map payloads" do
      assert {:error, {:invalid_payload_type, _}} = Sanitizer.sanitize("string")
      assert {:error, {:invalid_payload_type, _}} = Sanitizer.sanitize([1, 2, 3])
    end

    test "includes path information in error details" do
      long_string = String.duplicate("x", 1025)
      payload = %{"level1" => %{"level2" => long_string}}
      {:error, {:string_too_long, detail}} = Sanitizer.sanitize(payload)
      assert detail =~ "$.level1.level2"
      assert detail =~ "1025 bytes"
    end
  end

  describe "sanitize_with_schema/2" do
    test "validates against schema and strips unknown fields" do
      schema = %{"status" => :string, "count" => :number}
      payload = %{"status" => "ok", "count" => 42, "extra" => "stripped"}

      assert {:ok, result} = Sanitizer.sanitize_with_schema(payload, schema)
      assert result == %{"status" => "ok", "count" => 42}
      refute Map.has_key?(result, "extra")
    end

    test "accepts missing optional fields" do
      schema = %{"status" => :string, "count" => :number}
      payload = %{"status" => "ok"}

      assert {:ok, result} = Sanitizer.sanitize_with_schema(payload, schema)
      assert result == %{"status" => "ok"}
    end

    test "rejects type mismatches" do
      schema = %{"status" => :string}
      payload = %{"status" => 42}

      assert {:error, {:schema_violation, detail}} =
               Sanitizer.sanitize_with_schema(payload, schema)

      assert detail =~ "status"
      assert detail =~ "string"
    end

    test "accepts nil for any typed field" do
      schema = %{"status" => :string}
      payload = %{"status" => nil}

      assert {:ok, _result} = Sanitizer.sanitize_with_schema(payload, schema)
    end

    test "validates boolean fields" do
      schema = %{"active" => :boolean}

      assert {:ok, _} = Sanitizer.sanitize_with_schema(%{"active" => true}, schema)
      assert {:ok, _} = Sanitizer.sanitize_with_schema(%{"active" => false}, schema)

      assert {:error, {:schema_violation, _}} =
               Sanitizer.sanitize_with_schema(%{"active" => "yes"}, schema)
    end

    test "validates map fields" do
      schema = %{"data" => :map}
      assert {:ok, _} = Sanitizer.sanitize_with_schema(%{"data" => %{"k" => "v"}}, schema)

      assert {:error, {:schema_violation, _}} =
               Sanitizer.sanitize_with_schema(%{"data" => "not a map"}, schema)
    end

    test "validates list fields" do
      schema = %{"items" => :list}
      assert {:ok, _} = Sanitizer.sanitize_with_schema(%{"items" => [1, 2, 3]}, schema)

      assert {:error, {:schema_violation, _}} =
               Sanitizer.sanitize_with_schema(%{"items" => "not a list"}, schema)
    end

    test "supports :any type" do
      schema = %{"data" => :any}
      assert {:ok, _} = Sanitizer.sanitize_with_schema(%{"data" => "string"}, schema)
      assert {:ok, _} = Sanitizer.sanitize_with_schema(%{"data" => 42}, schema)
      assert {:ok, _} = Sanitizer.sanitize_with_schema(%{"data" => true}, schema)
    end

    test "still validates structural limits with schema" do
      schema = %{"data" => :string}
      long_string = String.duplicate("x", 1025)
      payload = %{"data" => long_string}

      assert {:error, {:string_too_long, _}} =
               Sanitizer.sanitize_with_schema(payload, schema)
    end
  end
end
