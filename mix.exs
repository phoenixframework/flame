defmodule FLAME.Runner.MixProject do
  use Mix.Project

  @source_url "https://github.com/phoenixframework/flame"
  @version "0.1.12"

  def project do
    [
      app: :flame,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      homepage_url: "http://www.phoenixframework.org",
      description: """
      Treat your entire application as a lambda, where modular parts can be executed on short-lived infrastructure.
      """
    ]
  end

  defp package do
    [
      maintainers: ["Chris McCord", "Jason Stiebs"],
      licenses: ["MIT"],
      links: %{
        GitHub: @source_url
      },
      files: ~w(lib CHANGELOG.md LICENSE.md mix.exs README.md)
    ]
  end

  defp docs do
    [
      source_url: @source_url,
      source_ref: @version,
      skip_code_autolink_to: [
        "FLAME.Runner",
        "FLAME.Terminator"
      ]
    ]
  end

  def application do
    [
      mod: {FLAME.Application, []},
      extra_applications: [:logger, inets: :optional, ssl: :optional]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, ">= 0.0.0"},
      {:castore, ">= 0.0.0"},
      {:mox, "~> 1.1.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
