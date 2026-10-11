defmodule Other.Thing do
  @moduledoc "The second app of the umbrella fixture (`other.thing`)."

  @doc "The answer of the second app."
  @spec answer() :: integer()
  def answer, do: 42
end
