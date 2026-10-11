defmodule Covenant.MutateRunnerTimeoutContractTest do
  use Covenant.Case, component: "covenant.mutate", async: true

  alias Covenant.Mutate.Runner

  @tag obligation: "covenant.mutate.I16"
  test "the baseline runs under --timeout, else the project's ExUnit timeout, else 60 seconds" do
    assert Runner.baseline_timeout(5_000, 120_000) == 5_000
    assert Runner.baseline_timeout(nil, 120_000) == 120_000
    assert Runner.baseline_timeout(nil, nil) == 60_000
  end
end
