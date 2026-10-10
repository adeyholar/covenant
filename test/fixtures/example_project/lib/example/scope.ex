defmodule Example.Scope do
  @moduledoc """
  Custom scope counters for `contracts/system/scope.yml` (`kind: module`).
  """

  @doc "The number of event kinds `Example.Counter` can record."
  @spec event_kinds() :: non_neg_integer()
  def event_kinds, do: 3
end
