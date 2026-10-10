defmodule Example.Scope do
  @moduledoc "Test support: module counters used by scope tests (mirrors the fixture project's module)."

  @doc "A fixed count."
  @spec event_kinds() :: non_neg_integer()
  def event_kinds, do: 3

  @doc "A counter that returns something other than an integer."
  @spec not_a_count() :: atom()
  def not_a_count, do: :nope
end
