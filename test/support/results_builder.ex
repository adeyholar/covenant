defmodule Covenant.ResultsBuilder do
  @moduledoc "Test support: builds `Covenant.Results` structs without running ExUnit."

  alias Covenant.Results
  alias Covenant.Results.Test

  @doc "A results struct with one passing test per obligation id (or `{id, state}` pair)."
  @spec results([String.t() | {String.t(), Test.state()}]) :: Results.t()
  def results(entries) do
    tests =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{id, state}, i} -> test(id, state, i)
        {id, i} -> test(id, :passed, i)
      end)

    %Results{apps: ["demo"], tests: tests}
  end

  defp test(id, state, i) do
    %Test{
      module: "DemoContractTest",
      name: "test #{id} ##{i}",
      file: "test/contract/demo_contract_test.exs",
      line: i,
      component: Covenant.Contract.Obligation.component_of(id),
      obligations: List.wrap(id),
      state: state
    }
  end
end
