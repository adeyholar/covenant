defmodule Covenant.Relay do
  @moduledoc """
  Relays the output of the `mix` subprocesses that `mix covenant.check` and
  `mix covenant.mutate` run to standard output, as text:

      System.cmd(mix, args, into: Covenant.Relay.new(), stderr_to_stdout: true)

  Valid UTF-8 passes through unchanged. A byte sequence that is not UTF-8 (a
  test printing a binary, a port's raw output) is written as U+FFFD instead of
  stopping the task with an `ArgumentError`, which is what writing it as text
  does. Writing the bytes raw instead (`IO.binstream/2`) would re-encode every
  non-ASCII character on a standard output in Unicode mode, the default. A
  character split across two chunks is held back until its last byte arrives.
  """

  @type t :: %__MODULE__{pending: binary()}

  defstruct pending: ""

  @doc "A relay to standard output."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Splits `data` into the text to write now, with every invalid sequence
  replaced by U+FFFD, and the bytes of a character cut off at its end, held
  for the next chunk.
  """
  @spec take(binary()) :: {String.t(), binary()}
  def take(data) do
    keep = byte_size(data) - cut_off(data)

    {String.replace_invalid(binary_part(data, 0, keep)),
     binary_part(data, keep, byte_size(data) - keep)}
  end

  # The number of bytes at the end of `data` that start a character whose
  # remaining bytes are still to come.
  defp cut_off(data) do
    size = byte_size(data)

    Enum.find_value(1..min(3, size)//1, 0, fn back ->
      <<byte>> = binary_part(data, size - back, 1)

      cond do
        byte < 0x80 -> 0
        byte >= 0xF0 and back < 4 -> back
        byte >= 0xE0 and byte < 0xF0 and back < 3 -> back
        byte >= 0xC0 and byte < 0xE0 and back < 2 -> back
        byte >= 0xC0 -> 0
        true -> nil
      end
    end)
  end

  defimpl Collectable do
    def into(relay) do
      {relay,
       fn
         acc, {:cont, chunk} ->
           {text, pending} = Covenant.Relay.take(acc.pending <> chunk)
           IO.write(text)
           %{acc | pending: pending}

         acc, :done ->
           IO.write(String.replace_invalid(acc.pending))
           %{acc | pending: ""}

         _acc, :halt ->
           :ok
       end}
    end
  end
end
