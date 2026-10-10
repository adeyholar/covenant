defmodule Mix.Tasks.Covenant.Conditions do
  @shortdoc "Re-checks the machine-checkable conditions of decision records"

  @moduledoc """
  Evaluates every record condition that carries a `check` and lists the
  suspect records: those with a premise that no longer holds.

      mix covenant.conditions
      mix covenant.conditions --contracts path
      mix covenant.conditions --verbose        # also print the conditions that hold

  Exits with status 1 when any record is suspect, so a scheduled job or a CI
  step can flag records to re-examine. See `Covenant.Contract.Condition` for
  the check kinds.
  """

  use Mix.Task

  alias Covenant.{Conditions, Contract, Error}

  @requirements ["app.config"]

  @switches [contracts: :string, verbose: :boolean]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}; see `mix help covenant.conditions`")
    end

    contracts_dir = opts[:contracts] || Covenant.contracts_dir()
    contract = load_contract(contracts_dir)
    ctx = Conditions.context()
    all = Conditions.check_all(contract, ctx)

    checked =
      for {_, outcomes} <- all, {_, outcome} <- outcomes, outcome != :unchecked, do: outcome

    suspects =
      Enum.filter(all, fn {_, outcomes} ->
        Enum.any?(outcomes, &match?({_, {:suspect, _}}, &1))
      end)

    if opts[:verbose] do
      Enum.each(all, fn {record, outcomes} ->
        Mix.shell().info("#{record.id} (#{record.file}:#{record.line})")

        Enum.each(outcomes, fn
          {condition, :unchecked} ->
            Mix.shell().info("  - #{condition.text} (not machine-checkable)")

          {condition, {:ok, detail}} ->
            Mix.shell().info("  ok #{condition.text} — #{detail}")

          {condition, {:suspect, reason}} ->
            Mix.shell().info("  SUSPECT #{condition.text} — #{reason}")
        end)
      end)

      Mix.shell().info("")
    end

    Enum.each(suspects, fn {record, outcomes} ->
      Mix.shell().error("#{record.file}:#{record.line}: record `#{record.id}` is suspect")

      for {condition, {:suspect, reason}} <- outcomes do
        Mix.shell().error("  - #{condition.text}: #{reason}")
      end
    end)

    Mix.shell().info(
      "covenant.conditions: #{map_size(contract.records)} record(s), " <>
        "#{length(checked)} machine-checkable condition(s), #{length(suspects)} suspect record(s)"
    )

    if suspects != [] do
      exit({:shutdown, 1})
    end

    :ok
  end

  defp load_contract(dir) do
    case Contract.load(dir) do
      {:ok, contract} ->
        contract

      {:error, errors} ->
        Enum.each(Error.sort(errors), &Mix.shell().error(Error.format(&1)))
        Mix.shell().error("covenant.conditions: the Contract in #{dir} could not be parsed")
        exit({:shutdown, 1})
    end
  end
end
