defmodule Example.Counter do
  @moduledoc """
  A bounded counter: the heavy-form example component (`example.counter`) of
  the Covenant fixture project.

  Its Contract lives in `contracts/example/counter.intent.md`; the reasons
  behind its values are decision records in `contracts/example/counter.decisions.yml`.
  """

  # record configurable-max
  @default_max 100

  @type event ::
          {:incremented, pos_integer()} | {:decremented, pos_integer()} | {:clamped, :max | :zero}

  @type t :: %__MODULE__{value: non_neg_integer(), max: pos_integer(), events: [event()]}

  defstruct value: 0, max: @default_max, events: []

  @doc "Builds a counter at zero. `max:` sets the cap (default 100)."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max = Keyword.get(opts, :max, @default_max)

    if not (is_integer(max) and max > 0) do
      raise ArgumentError, "max must be a positive integer, got: #{inspect(max)}"
    end

    %__MODULE__{value: 0, max: max, events: []}
  end

  @doc "Adds `by` (a positive integer); a result above `max` is clamped at `max`."
  @spec increment(t(), pos_integer()) :: t()
  def increment(%__MODULE__{} = counter, by \\ 1) do
    check_step!(by)

    if counter.value + by > counter.max do
      record(%{counter | value: counter.max}, {:clamped, :max})
    else
      record(%{counter | value: counter.value + by}, {:incremented, by})
    end
  end

  @doc "Subtracts `by` (a positive integer); a result below zero is clamped at zero (record clamp-at-zero)."
  @spec decrement(t(), pos_integer()) :: t()
  def decrement(%__MODULE__{} = counter, by \\ 1) do
    check_step!(by)

    if counter.value - by < 0 do
      record(%{counter | value: 0}, {:clamped, :zero})
    else
      record(%{counter | value: counter.value - by}, {:decremented, by})
    end
  end

  @doc "The current value."
  @spec value(t()) :: non_neg_integer()
  def value(%__MODULE__{value: value}), do: value

  @doc "Every event so far, oldest first."
  @spec events(t()) :: [event()]
  def events(%__MODULE__{events: events}), do: events

  @doc "The persisted form: exactly the keys `\"value\"` and `\"max\"`."
  @spec to_map(t()) :: %{String.t() => non_neg_integer()}
  def to_map(%__MODULE__{value: value, max: max}), do: %{"value" => value, "max" => max}

  # record positive-steps
  defp check_step!(by) when is_integer(by) and by > 0, do: :ok

  defp check_step!(by) do
    raise ArgumentError, "step must be a positive integer, got: #{inspect(by)}"
  end

  defp record(counter, event), do: %{counter | events: counter.events ++ [event]}
end
