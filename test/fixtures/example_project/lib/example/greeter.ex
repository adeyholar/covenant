defmodule Example.Greeter do
  @moduledoc """
  Greets people: the light-form example component (`example.greeter`) of the
  Covenant fixture project. See `contracts/example/greeter.obligations.md`.
  """

  @doc "Greets `name`; `nil` and the empty string get `\"Hello, stranger!\"`."
  @spec greet(String.t() | nil) :: String.t()
  def greet(name) when name in [nil, ""], do: "Hello, stranger!"
  def greet(name) when is_binary(name), do: "Hello, #{name}!"

  @doc """
  Clamps a count at zero. Deliberately duplicates the counter's rule instead
  of depending on `Example.Counter` (exception `example.greeter.I2`).
  """
  @spec clamp(integer()) :: non_neg_integer()
  def clamp(n) when n < 0, do: 0
  def clamp(n), do: n
end
