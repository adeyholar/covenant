defmodule Covenant.JSON do
  @moduledoc """
  A deterministic, pretty-printed JSON encoder for the files Covenant commits
  and diffs (`contracts/coverage.json`, test results).

  Map keys are sorted so two runs over the same Contract produce the same
  bytes. Values are encoded with Elixir's `JSON` module.
  """

  @indent "  "

  @doc "Encodes `term` as pretty-printed JSON with sorted object keys."
  @spec pretty(term()) :: iodata()
  def pretty(term), do: encode(term, 0)

  defp encode(map, _depth) when is_map(map) and map_size(map) == 0, do: "{}"

  defp encode(map, depth) when is_map(map) do
    inner = String.duplicate(@indent, depth + 1)

    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [inner, JSON.encode!(k), ": ", encode(v, depth + 1)] end)

    ["{\n", Enum.intersperse(pairs, ",\n"), "\n", String.duplicate(@indent, depth), "}"]
  end

  defp encode([], _depth), do: "[]"

  defp encode(list, depth) when is_list(list) do
    inner = String.duplicate(@indent, depth + 1)
    items = Enum.map(list, &[inner, encode(&1, depth + 1)])
    ["[\n", Enum.intersperse(items, ",\n"), "\n", String.duplicate(@indent, depth), "]"]
  end

  defp encode(value, _depth), do: JSON.encode!(value)
end
