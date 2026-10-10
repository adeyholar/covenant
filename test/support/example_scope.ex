defmodule Example.Scope do
  @moduledoc "Test support: module counters used by scope tests (mirrors the fixture project's module)."

  @doc "A fixed count."
  @spec event_kinds() :: non_neg_integer()
  def event_kinds, do: 3

  @doc "A counter that returns something other than an integer."
  @spec not_a_count() :: atom()
  def not_a_count, do: :nope

  @doc "A counter that is a stub: it raises."
  @spec unimplemented() :: no_return()
  def unimplemented, do: raise(ArgumentError, "not implemented")

  @doc "A counter that throws."
  @spec thrower() :: no_return()
  def thrower, do: throw(:stub)

  @doc "A counter that exits."
  @spec exiter() :: no_return()
  def exiter, do: exit(:stub)
end
