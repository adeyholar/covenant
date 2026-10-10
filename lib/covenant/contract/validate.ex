defmodule Covenant.Contract.Validate do
  @moduledoc """
  Cross-reference checks over a loaded Contract.

  * an obligation's `record` must name an existing decision record;
  * a record's `invariant` entries must name existing obligations;
  * a record's `superseded_by` and `depends_on` must name existing records;
  * a scope ceiling's `record` must name an existing record.
  """

  alias Covenant.Contract
  alias Covenant.Error

  @doc "Returns every dangling reference as an error."
  @spec dangling(Contract.t()) :: [Error.t()]
  def dangling(%Contract{} = contract) do
    obligation_refs(contract) ++ record_refs(contract) ++ ceiling_refs(contract)
  end

  defp obligation_refs(contract) do
    for obligation <- Contract.obligations(contract),
        obligation.record != nil,
        Contract.record(contract, obligation.record) == nil do
      Error.new(
        obligation.file,
        obligation.line,
        "obligation `#{obligation.id}` cites record `#{obligation.record}`, which does not exist"
      )
    end
  end

  defp record_refs(contract) do
    contract.records
    |> Map.values()
    |> Enum.sort_by(&{&1.file, &1.line})
    |> Enum.flat_map(fn record ->
      invariants =
        for id <- record.invariant, Contract.obligation(contract, id) == nil do
          Error.new(
            record.file,
            record.line,
            "record `#{record.id}` protects invariant `#{id}`, which does not exist"
          )
        end

      superseded =
        case record.superseded_by do
          nil ->
            []

          id ->
            if Contract.record(contract, id),
              do: [],
              else: [
                Error.new(
                  record.file,
                  record.line,
                  "record `#{record.id}` is superseded by `#{id}`, which does not exist"
                )
              ]
        end

      depends =
        for id <- record.depends_on, Contract.record(contract, id) == nil do
          Error.new(
            record.file,
            record.line,
            "record `#{record.id}` depends on `#{id}`, which does not exist"
          )
        end

      invariants ++ superseded ++ depends
    end)
  end

  defp ceiling_refs(contract) do
    for ceiling <- contract.ceilings,
        ceiling.record != nil,
        Contract.record(contract, ceiling.record) == nil do
      Error.new(
        ceiling.file,
        ceiling.line,
        "ceiling `#{ceiling.name}` cites record `#{ceiling.record}`, which does not exist"
      )
    end
  end
end
