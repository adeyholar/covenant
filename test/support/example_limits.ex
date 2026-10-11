defmodule Covenant.ExampleLimits do
  @moduledoc "Test support: a module with a `limits/0` of decision values, the target of `value` checks."

  @doc "Decision values: atom keys, a string key, a shadowed key, nesting, a list, an atom, a nil."
  @spec limits() :: map()
  def limits do
    %{
      "dup" => 2,
      "stringy" => 7,
      claim_batch: 20,
      ratio: 0.5,
      backoff_s: [60, 300],
      mode: :fast,
      enabled: true,
      name: "invoices",
      nothing: nil,
      disabled: false,
      nested: %{"deep" => %{depth: 3}},
      dup: 1
    }
  end

  @doc "A value with no path to walk."
  @spec answer() :: 42
  def answer, do: 42

  @doc "A function name ending in `?`."
  @spec ready?() :: true
  def ready?, do: true

  @doc "A call that raises."
  @spec boom() :: no_return()
  def boom, do: raise(ArgumentError, "no limits today")

  @doc "A call that throws."
  @spec thrower() :: no_return()
  def thrower, do: throw(:nope)
end
