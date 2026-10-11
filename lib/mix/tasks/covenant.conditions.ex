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

  `file` conditions and `mix.lock` resolve against `Covenant.root/0`, whichever
  directory the task runs in (`--contracts` does not move it).

  A `value` check calls a function of the running project, so the project is
  compiled and its modules loaded first. A module that is not compiled in this
  VM leaves its condition unchecked (a count is printed, `--verbose` says why);
  it never fails the run.
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
    ctx = Conditions.context(root: Covenant.root())
    all = Conditions.check_all(contract, ctx)

    checked =
      for {_, outcomes} <- all,
          {_, outcome} <- outcomes,
          match?({status, _} when status in [:ok, :suspect], outcome),
          do: outcome

    not_checkable_here =
      for {_, outcomes} <- all, {_, {:unchecked, _}} = outcome <- outcomes, do: outcome

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

          {condition, {:unchecked, reason}} ->
            Mix.shell().info("  - #{condition.text} (not checked: #{reason})")

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

    if not_checkable_here != [] do
      Mix.shell().info(
        "covenant.conditions: #{length(not_checkable_here)} condition(s) not checked in this VM " <>
          "(--verbose says why)"
      )
    end

    if suspects != [] do
      exit({:shutdown, 1})
    end

    :ok
  end

  defp load_contract(dir) do
    case Contract.load(dir, sibling: sibling_relative()) do
      {:ok, contract} ->
        contract

      {:error, errors} ->
        Enum.each(Error.sort(errors), &Mix.shell().error(Error.format(&1)))
        Mix.shell().error("covenant.conditions: the Contract in #{dir} could not be parsed")
        exit({:shutdown, 1})
    end
  end

  defp sibling_relative do
    sibling = Covenant.sibling_dir()
    sibling && Path.relative_to_cwd(sibling)
  end
end
