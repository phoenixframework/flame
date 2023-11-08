defmodule Dragonfly.Runner.MixProject do
  use Mix.Project

  def project do
    [
      app: :dragonfly,
      version: "0.1.3",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      source_url: "https://github.com/phoenixframework/dragonfly",
      homepage_url: "http://www.phoenixframework.org",
      description: """
      Remote empheral application process runner.
      """
    ]
  end

  defp package do
    [
      maintainers: ["Chris McCord", "Jason Stiebs"],
      licenses: ["MIT"],
      links: %{
        GitHub: "https://github.com/phoenixframework/dragonfly"
      },
      files: ~w(lib CHANGELOG.md LICENSE.md mix.exs README.md)
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Dragonfly.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.4.5"},
      {:mox, "~> 1.1.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
