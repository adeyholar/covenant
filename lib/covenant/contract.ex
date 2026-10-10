defmodule Covenant.Contract do
  @moduledoc """
  The parsed Contract: every component, every decision record and every
  scope ceiling found in a contracts directory.

  ```
  contracts/
    system/intent.md            # component "system" (form :system)
    system/decisions.yml        # system-level records
    system/scope.yml            # scope ceilings
    <app>/<name>.intent.md      # heavy form   -> component "<app>.<name>"
    <app>/<name>.obligations.md # light form   -> component "<app>.<name>"
    <app>/<name>.decisions.yml  # that component's records
  ```

  `load/1` parses everything and either returns the Contract or every
  problem found, each anchored to a file and line. Cross-reference checks
  (dangling `record`, `invariant`, `superseded_by`, ...) live in
  `Covenant.Contract.Validate` and run from `mix covenant.check`, so a
  dangling reference does not stop contract tests from compiling.
  """

  alias Covenant.Contract.{Ceiling, Component, Obligation, Record}
  alias Covenant.Error
  alias Covenant.Parser

  @type t :: %__MODULE__{
          dir: Path.t(),
          components: %{String.t() => Component.t()},
          records: %{String.t() => Record.t()},
          ceilings: [Ceiling.t()]
        }

  defstruct dir: nil, components: %{}, records: %{}, ceilings: []

  @doc "Loads the Contract from `dir`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def load(dir) do
    if File.dir?(dir) do
      do_load(dir)
    else
      {:error, [Error.new(dir, nil, "contracts directory not found")]}
    end
  end

  @doc "Loads the Contract from `dir`, raising `Covenant.ContractError` on problems."
  @spec load!(Path.t()) :: t()
  def load!(dir) do
    case load(dir) do
      {:ok, contract} -> contract
      {:error, errors} -> raise Covenant.ContractError, errors: errors
    end
  end

  defp do_load(dir) do
    component_results =
      for {file, form} <- component_files(dir) do
        Parser.Markdown.parse_file(file, component_id(dir, file), form)
      end

    record_results =
      for file <- record_files(dir) do
        Parser.Records.parse_file(file, component_id(dir, file)) |> tag(file)
      end

    scope_path = Path.join([dir, "system", "scope.yml"])

    scope_result =
      if File.exists?(scope_path), do: Parser.Scope.parse_file(scope_path), else: {:ok, []}

    errors =
      Enum.flat_map(component_results ++ record_results ++ [scope_result], fn
        {:error, errors} -> errors
        _ -> []
      end)

    components = for {:ok, %Component{} = c} <- component_results, do: c
    records = for {:ok, {_file, records}} <- record_results, record <- records, do: record

    case errors ++ duplicate_components(components) ++ duplicate_records(records) do
      [] -> {:ok, assemble(dir, components, record_results, elem(scope_result, 1))}
      errors -> {:error, errors}
    end
  end

  defp tag({:ok, records}, file), do: {:ok, {file, records}}
  defp tag(error, _file), do: error

  defp assemble(dir, components, record_results, ceilings) do
    by_component =
      for {:ok, {file, records}} <- record_results, into: %{} do
        id = component_id(dir, file)
        {id, {file, records}}
      end

    components =
      Map.new(components, fn component ->
        {file, records} = Map.get(by_component, component.id, {nil, []})
        {component.id, %{component | records: records, records_file: file}}
      end)

    records =
      for {:ok, {_file, records}} <- record_results, record <- records, into: %{} do
        {record.id, record}
      end

    %__MODULE__{dir: dir, components: components, records: records, ceilings: ceilings}
  end

  # -- files ------------------------------------------------------------------

  defp component_files(dir) do
    heavy = dir |> Path.join("*/*.intent.md") |> Path.wildcard() |> Enum.map(&{&1, :heavy})
    light = dir |> Path.join("*/*.obligations.md") |> Path.wildcard() |> Enum.map(&{&1, :light})
    system = Path.join([dir, "system", "intent.md"])
    system = if File.exists?(system), do: [{system, :system}], else: []
    Enum.sort(heavy ++ light ++ system)
  end

  defp record_files(dir) do
    system = Path.join([dir, "system", "decisions.yml"])
    system = if File.exists?(system), do: [system], else: []
    Enum.sort(Path.wildcard(Path.join(dir, "*/*.decisions.yml")) ++ system)
  end

  @doc """
  Derives a component id from a file path inside the contracts directory:
  `agora/wake_ingest.intent.md` is `agora.wake_ingest`; anything under
  `system/` is `system`.
  """
  @spec component_id(Path.t(), Path.t()) :: String.t()
  def component_id(dir, file) do
    relative = Path.relative_to(file, dir)

    case Path.split(relative) do
      ["system" | _] ->
        "system"

      parts ->
        base = parts |> List.last() |> String.split(".") |> hd()
        (Enum.drop(parts, -1) ++ [base]) |> Enum.join(".")
    end
  end

  defp duplicate_components(components) do
    components
    |> Enum.group_by(& &1.id)
    |> Enum.flat_map(fn
      {_, [_]} ->
        []

      {id, [first | rest]} ->
        Enum.map(
          rest,
          &Error.new(
            &1.file,
            1,
            "component `#{id}` is declared twice (also in #{first.file}); use either the intent or the obligations form"
          )
        )
    end)
  end

  defp duplicate_records(records) do
    records
    |> Enum.group_by(& &1.id)
    |> Enum.flat_map(fn
      {_, [_]} ->
        []

      {id, [first | rest]} ->
        Enum.map(
          rest,
          &Error.new(
            &1.file,
            &1.line,
            "record `#{id}` is declared twice (also in #{first.file}:#{first.line})"
          )
        )
    end)
  end

  # -- lookups ----------------------------------------------------------------

  @doc "All obligations across components, in a stable order."
  @spec obligations(t()) :: [Obligation.t()]
  def obligations(%__MODULE__{components: components}) do
    components
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.flat_map(& &1.obligations)
  end

  @doc "Finds an obligation by id."
  @spec obligation(t(), String.t()) :: Obligation.t() | nil
  def obligation(%__MODULE__{} = contract, id) do
    case Map.get(contract.components, Obligation.component_of(id)) do
      nil -> nil
      component -> Enum.find(component.obligations, &(&1.id == id))
    end
  end

  @doc "Finds a component by id."
  @spec component(t(), String.t()) :: Component.t() | nil
  def component(%__MODULE__{components: components}, id), do: Map.get(components, id)

  @doc "Finds a record by id."
  @spec record(t(), String.t()) :: Record.t() | nil
  def record(%__MODULE__{records: records}, id), do: Map.get(records, id)

  @doc "Component ids, sorted."
  @spec component_ids(t()) :: [String.t()]
  def component_ids(%__MODULE__{components: components}),
    do: components |> Map.keys() |> Enum.sort()
end
