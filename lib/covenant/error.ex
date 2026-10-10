defmodule Covenant.Error do
  @moduledoc """
  A problem found in the Contract, with file and line provenance.

  Every parser and every check in Covenant reports problems as this struct so
  that `mix covenant.check` can print them uniformly as `file:line: message`,
  sorted by location.
  """

  @type t :: %__MODULE__{
          file: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t()
        }

  @enforce_keys [:message]
  defstruct [:file, :line, :message]

  @doc "Builds an error anchored at `file:line`."
  @spec new(String.t() | nil, pos_integer() | nil, String.t()) :: t()
  def new(file, line, message), do: %__MODULE__{file: file, line: line, message: message}

  @doc "Formats an error as `file:line: message` (omitting parts that are unknown)."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{file: nil, message: message}), do: message

  def format(%__MODULE__{file: file, line: nil, message: message}),
    do: "#{file}: #{message}"

  def format(%__MODULE__{file: file, line: line, message: message}),
    do: "#{file}:#{line}: #{message}"

  @doc "Sorts errors by file, then line, so output is stable between runs."
  @spec sort([t()]) :: [t()]
  def sort(errors), do: Enum.sort_by(errors, &{&1.file || "", &1.line || 0, &1.message})
end

defmodule Covenant.ContractError do
  @moduledoc """
  Raised by the bang variants of the loaders when the Contract cannot be parsed.

  The message lists every problem found, one per line, as `file:line: message`.
  """

  defexception [:errors]

  @type t :: %__MODULE__{errors: [Covenant.Error.t()]}

  @impl true
  def message(%__MODULE__{errors: errors}) do
    lines = errors |> Covenant.Error.sort() |> Enum.map(&("  " <> Covenant.Error.format(&1)))
    "the Contract has #{length(errors)} problem(s):\n" <> Enum.join(lines, "\n")
  end
end
