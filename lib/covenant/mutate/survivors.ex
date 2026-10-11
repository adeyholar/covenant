defmodule Covenant.Mutate.Survivors do
  @moduledoc """
  The survivor sort: `contracts/<app>/<component>.survivors.yml` annotates
  every surviving mutant with the judgment a human made about it.

  ```yaml
  - at: lib/example/counter.ex:29:17
    operator: element_removal
    mutation: "`value: 0` → `(removed)`"   # optional; needed when two mutants share at + operator
    sort: equivalent
    reason: The struct default for value is already 0.
  ```

  `sort` is one of `equivalent`, `log-only`, `dead-code`, `timeout`,
  `evaluation-gap`, `decision-hole` or `unpromised`.

  A primitive of the sibling layout declares its survivors in
  `contract/<primitive>/mutants.md` instead, as flinch does: `equivalent` and
  `unpromised` blocks of `Module.function/arity: from -> to` lines under a
  heading that gives the reason (`Covenant.Parser.Primitive.declarations/2`).
  `equivalent` maps onto the `equivalent` sort and `unpromised` onto
  `unpromised`. A survivor without an annotation and an
  annotation without a survivor both fail `mix covenant.mutate`, the way a
  stale `kind: exception` fails `mix covenant.check`: the counts only say
  where to look, the sort is where the judgment is.
  """

  alias Covenant.Error
  alias Covenant.Mutate.Mutant
  alias Covenant.Parser.Primitive

  @sorts ~w(equivalent log-only dead-code timeout evaluation-gap decision-hole unpromised)
  @item_line ~r/^-[ \t]/

  defmodule Annotation do
    @moduledoc """
    One annotated survivor. An entry of a survivors file names a site (`at`,
    `operator`, optional `mutation`); a declaration in a primitive's
    `mutants.md` names a `unit` (`Module.function/arity`) and the mutation's
    `from` and `to`, or neither for a wildcard over the unit.
    """

    @type t :: %__MODULE__{
            at: String.t(),
            operator: String.t(),
            mutation: String.t() | nil,
            sort: String.t(),
            reason: String.t(),
            file: String.t(),
            line: pos_integer(),
            unit: String.t() | nil,
            from: String.t() | nil,
            to: String.t() | nil
          }

    @enforce_keys [:at, :operator, :sort, :reason, :file, :line]
    defstruct [:at, :operator, :mutation, :sort, :reason, :file, :line, :unit, :from, :to]
  end

  @doc "The sort names, in the order the survivors file documents them."
  @spec sorts() :: [String.t()]
  def sorts, do: @sorts

  @doc """
  Where a component's annotations live: `<contracts dir>/<app>/<name>.survivors.yml`,
  or `mutants.md` beside a primitive's README.
  """
  @spec path(Path.t(), Covenant.Contract.Component.t()) :: Path.t()
  def path(_contracts_dir, %{form: :primitive, file: readme}),
    do: Path.join(Path.dirname(readme), "mutants.md")

  def path(contracts_dir, %{form: :system}),
    do: Path.join([contracts_dir, "system", "survivors.yml"])

  def path(contracts_dir, component),
    do: Path.join([contracts_dir, component.app, "#{component.name}.survivors.yml"])

  @doc "Reads the annotations file (a `mutants.md` by its extension); a missing file is an empty list."
  @spec load(Path.t()) :: {:ok, [Annotation.t()]} | {:error, [Error.t()]}
  def load(path) do
    case File.read(path) do
      {:ok, text} ->
        if Path.extname(path) == ".md",
          do: Primitive.declarations(text, path),
          else: parse(text, path)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, [Error.new(path, nil, "cannot read file: #{:file.format_error(reason)}")]}
    end
  end

  @doc "Parses annotations from `text`; `file` is used for provenance."
  @spec parse(String.t(), Path.t()) :: {:ok, [Annotation.t()]} | {:error, [Error.t()]}
  def parse(text, file) do
    if String.trim(text) == "" do
      {:ok, []}
    else
      case YamlElixir.read_from_string(text) do
        {:ok, nil} ->
          {:ok, []}

        {:ok, items} when is_list(items) ->
          lines = item_lines(text)

          items
          |> Enum.with_index()
          |> Enum.map(fn {item, i} -> annotation(item, i, Enum.at(lines, i, 1), file) end)
          |> collect()

        {:ok, _} ->
          {:error, [Error.new(file, 1, "survivors file must be a YAML list of annotations")]}

        {:error, %{line: line, message: message}} ->
          {:error, [Error.new(file, line, "invalid YAML: #{message}")]}

        {:error, error} ->
          {:error, [Error.new(file, 1, "invalid YAML: #{Exception.message(error)}")]}
      end
    end
  end

  defp collect(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, a} -> a end)}
      {_, errors} -> {:error, Enum.flat_map(errors, fn {:error, e} -> e end)}
    end
  end

  defp item_lines(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(@item_line, line) end)
    |> Enum.map(fn {_, n} -> n end)
  end

  defp annotation(%{} = item, index, line, file) do
    label = "annotation ##{index + 1}"
    operators = Enum.map(Mutant.operators(), &Atom.to_string/1)

    errors =
      [
        string(item, "at", label, file, line),
        string(item, "operator", label, file, line),
        string(item, "sort", label, file, line),
        string(item, "reason", label, file, line),
        enum(item, "operator", operators, label, file, line),
        enum(item, "sort", @sorts, label, file, line),
        at_shape(item, label, file, line)
      ]
      |> List.flatten()

    case errors do
      [] ->
        {:ok,
         %Annotation{
           at: item["at"],
           operator: item["operator"],
           mutation: item["mutation"],
           sort: item["sort"],
           reason: to_string(item["reason"]),
           file: file,
           line: line
         }}

      errors ->
        {:error, errors}
    end
  end

  defp annotation(_item, index, line, file),
    do: {:error, [Error.new(file, line, "annotation ##{index + 1} must be a mapping")]}

  defp string(item, key, label, file, line) do
    case Map.get(item, key) do
      nil -> Error.new(file, line, "#{label} is missing `#{key}`")
      "" -> Error.new(file, line, "#{label} has an empty `#{key}`")
      value when is_binary(value) -> []
      value -> Error.new(file, line, "#{label} `#{key}` must be a string, got #{inspect(value)}")
    end
  end

  defp enum(item, key, allowed, label, file, line) do
    case Map.get(item, key) do
      value when is_binary(value) and value != "" ->
        if value in allowed,
          do: [],
          else:
            Error.new(
              file,
              line,
              "#{label} has unknown `#{key}` `#{value}` (expected one of: #{Enum.join(allowed, ", ")})"
            )

      _ ->
        []
    end
  end

  defp at_shape(%{"at" => at}, label, file, line) when is_binary(at) do
    if Regex.match?(~r/^.+:\d+:\d+$/, at),
      do: [],
      else: Error.new(file, line, "#{label} `at` must be `file:line:column`, got `#{at}`")
  end

  defp at_shape(_, _, _, _), do: []

  @doc "The annotation that covers `mutant`, if any."
  @spec find([Annotation.t()], Mutant.t()) :: Annotation.t() | nil
  def find(annotations, %Mutant{} = mutant), do: Enum.find(annotations, &matches?(&1, mutant))

  @doc """
  True when the annotation names the mutant's location, operator and (if given)
  mutation; a declaration, when it names the mutant's unit and (unless it is a
  wildcard) its `from` and `to`.
  """
  @spec matches?(Annotation.t(), Mutant.t()) :: boolean()
  def matches?(%Annotation{unit: unit} = annotation, %Mutant{} = mutant) when unit != nil do
    unit == unit(mutant) and
      (annotation.from == nil or (annotation.from == mutant.from and annotation.to == mutant.to))
  end

  def matches?(%Annotation{} = annotation, %Mutant{} = mutant) do
    annotation.at == Mutant.at(mutant) and
      annotation.operator == Atom.to_string(mutant.operator) and
      (annotation.mutation == nil or annotation.mutation == Mutant.mutation(mutant))
  end

  @doc "The unit a mutant belongs to, `Module.function/arity`, or the module for code outside a function."
  @spec unit(Mutant.t()) :: String.t()
  def unit(%Mutant{module: module, function: nil}), do: module
  def unit(%Mutant{module: module, function: function}), do: "#{module}.#{function}"

  @doc """
  An entry for a survivor, ready to paste: a YAML entry for a survivors file,
  or (`format: :md`) a declaration line for a primitive's `mutants.md`.
  """
  @spec template(Mutant.t(), keyword()) :: String.t()
  def template(mutant, opts \\ [])

  def template(%Mutant{} = mutant, format: :md),
    do: "#{unit(mutant)}: #{mutant.from} -> #{mutant.to}"

  def template(%Mutant{} = mutant, _opts) do
    """
    - at: #{Mutant.at(mutant)}
      operator: #{mutant.operator}
      mutation: #{inspect(Mutant.mutation(mutant))}
      sort: #{if mutant.verdict == :timeout, do: "timeout", else: "evaluation-gap"}
      reason: TODO
    """
  end
end
