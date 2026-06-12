defmodule TriOnyx.DocsConsistencyTest do
  @moduledoc """
  Keeps the reference docs honest: every HTTP route and every protocol
  message type must at least be mentioned in its reference page. The
  checks are presence checks (backticked identifier appears in the doc),
  not prose validation — enough to catch silently added/renamed
  endpoints and message types.
  """
  use ExUnit.Case, async: true

  test "every router route is documented in docs/api-reference.md" do
    routes =
      "lib/tri_onyx/router.ex"
      |> File.read!()
      |> then(&Regex.scan(~r/^\s+(get|post|put|delete)\s+"([^"]+)"/m, &1))
      |> Enum.map(fn [_, method, path] -> {String.upcase(method), path} end)

    assert routes != [], "no routes found in router.ex — did the macro syntax change?"

    doc = File.read!("docs/api-reference.md")

    undocumented =
      Enum.reject(routes, fn {_method, path} -> String.contains?(doc, "`#{path}`") end)

    assert undocumented == [],
           "routes missing from docs/api-reference.md: #{inspect(undocumented)}"
  end

  test "every protocol message type is documented in docs/protocol.md" do
    source = File.read!("runtime/protocol.py")

    # Inbound types: the _INBOUND_PARSERS dict maps type strings to classes.
    inbound =
      Regex.scan(~r/^\s*"([a-z_]+)": [A-Z]\w+,$/m, source)
      |> Enum.map(fn [_, type] -> type end)

    # Outbound types: every emitter builds a payload with a literal type.
    outbound =
      Regex.scan(~r/"type": "([a-z_]+)"/, source)
      |> Enum.map(fn [_, type] -> type end)

    assert inbound != [], "no inbound parser entries found in protocol.py"
    assert outbound != [], "no outbound type literals found in protocol.py"

    doc = File.read!("docs/protocol.md")

    undocumented =
      (inbound ++ outbound)
      |> Enum.uniq()
      |> Enum.reject(&String.contains?(doc, "`#{&1}`"))

    assert undocumented == [],
           "protocol message types missing from docs/protocol.md: #{inspect(undocumented)}"
  end
end
