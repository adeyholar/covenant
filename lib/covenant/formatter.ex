defmodule Covenant.Formatter do
  @moduledoc """
  An ExUnit formatter that records which obligations had passing and failing
  tests and writes them as JSON when the suite finishes.

  Add it next to the CLI formatter in `test/test_helper.exs`:

  ```elixir
  ExUnit.start(formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
  ```

  or pass it on the command line, which is what `mix covenant.check` does:

  ```
  mix test test/contract --formatter Covenant.Formatter --formatter ExUnit.CLIFormatter
  ```

  Only tests tagged with `obligation` are recorded. The file is written to
  `Covenant.results_dir/0` as `<app>.json`, where `<app>` is the Mix project
  being tested (`"app"` outside Mix).
  """

  use GenServer

  alias Covenant.Results

  @impl true
  def init(_opts) do
    {:ok, %{tests: []}}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    case Results.from_ex_unit(test) do
      nil -> {:noreply, state}
      entry -> {:noreply, %{state | tests: [entry | state.tests]}}
    end
  end

  def handle_cast({:suite_finished, _times}, state) do
    Results.write(Covenant.results_dir(), app_name(), Enum.reverse(state.tests))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc "The name used for the results file: the Mix app being tested."
  @spec app_name() :: String.t()
  def app_name do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Mix.Project.config() |> Keyword.get(:app, :app) |> to_string()
    else
      "app"
    end
  end
end
