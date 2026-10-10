defmodule Example.Scope do
  @moduledoc """
  Custom scope counters for `contracts/system/scope.yml` (`kind: module`).
  """

  @doc "The number of event kinds `Example.Counter` can record."
  @spec event_kinds() :: non_neg_integer()
  def event_kinds, do: 3

  @doc "A counter that is a stub: it raises."
  @spec unimplemented() :: no_return()
  def unimplemented, do: raise(RuntimeError, "not implemented")
end
