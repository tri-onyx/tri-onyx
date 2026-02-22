defmodule TriOnyx.MixProject do
  use Mix.Project

  def project do
    [
      app: :tri_onyx,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {TriOnyx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # JSON encoding/decoding
      {:jason, "~> 1.4"},

      # YAML frontmatter parsing
      {:yaml_elixir, "~> 2.9"},

      # HTTP/WebSocket server
      {:bandit, "~> 1.2"},

      # HTTP request routing
      {:plug, "~> 1.16"},

      # WebSocket upgrade adapter for Bandit/Plug
      {:websock_adapter, "~> 0.5"},

      # Cron-like job scheduling
      {:quantum, "~> 3.5"},

      # Filesystem change notifications
      {:file_system, "~> 1.0"},

      # SMTP email sending (iconv required by gen_smtp for MIME charset conversion)
      {:gen_smtp, "~> 1.2"},
      {:iconv, "~> 1.0"},

      # Static analysis and linting
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      lint: ["format --check-formatted", "credo --strict"],
      check: ["compile --warnings-as-errors", "dialyzer", "lint", "test"]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix]
    ]
  end
end
