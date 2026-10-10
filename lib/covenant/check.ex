defmodule Covenant.Check do
  @moduledoc """
  The checks behind `mix covenant.check`, as a pure function of the Contract
  and a test run.

  `run/3` fails (returns problems) on:

  * dangling `record`, `invariant`, `superseded_by` or `depends_on` references;
  * an active obligation with no tagged test;
  * a tag naming an obligation the Contract does not declare;
  * a tagged test that failed or could not run;
  * a `kind: exception` whose `target` no longer exists (stale exception);
  * a scope ceiling whose count exceeds its limit.

  Malformed blocks are reported earlier, by `Covenant.Contract.load/1`.
  """

  alias Covenant.Contract
  alias Covenant.Contract.{Ceiling, Component, Obligation, Validate}
  alias Covenant.{Coverage, Error, Results, Target}

  defmodule Report do
    @moduledoc "What a check produced: sorted problems and the coverage table."

    @type t :: %__MODULE__{problems: [Covenant.Error.t()], coverage: Covenant.Coverage.t()}

    @enforce_keys [:problems, :coverage]
    defstruct [:problems, :coverage]

    @doc "True when no problem was found."
    @spec ok?(t()) :: boolean()
    def ok?(%__MODULE__{problems: []}), do: true
    def ok?(%__MODULE__{}), do: false
  end

  @doc """
  Runs every check. Options:

  * `:root` — the project root that file targets and glob counters resolve
    against (default: the current directory).
  """
  @spec run(Contract.t(), Results.t(), keyword()) :: Report.t()
  def run(%Contract{} = contract, %Results{} = results, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    by_obligation = Results.by_obligation(results)

    problems =
      Validate.dangling(contract) ++
        untested(contract, by_obligation) ++
        unknown_tags(contract, by_obligation) ++
        failing(contract, by_obligation) ++
        stale_exceptions(contract, root) ++
        ceilings(contract, root)

    %Report{problems: Error.sort(problems), coverage: Coverage.compute(contract, results)}
  end

  defp untested(contract, by_obligation) do
    for %Obligation{} = obligation <- Contract.obligations(contract),
        Obligation.testable?(obligation),
        Map.get(by_obligation, obligation.id, []) == [] do
      Error.new(
        obligation.file,
        obligation.line,
        "active obligation `#{obligation.id}` has no tagged test; " <>
          "add `@tag obligation: \"#{obligation.id}\"` to the contract test that proves it"
      )
    end
  end

  defp unknown_tags(contract, by_obligation) do
    for {id, tests} <- Enum.sort(by_obligation),
        Contract.obligation(contract, id) == nil,
        test <- tests do
      Error.new(test.file, test.line, "#{test.name} is tagged with unknown obligation `#{id}`")
    end
  end

  defp failing(contract, by_obligation) do
    for {id, tests} <- Enum.sort(by_obligation),
        Contract.obligation(contract, id) != nil,
        test <- Enum.uniq_by(tests, &{&1.module, &1.name}),
        test.state in [:failed, :invalid] do
      Error.new(test.file, test.line, "#{test.name} (obligation `#{id}`) #{test.state}")
    end
  end

  defp stale_exceptions(contract, root) do
    for %Component{} = component <- Map.values(contract.components),
        %Obligation{} = exception <- Component.exceptions(component),
        problem = stale_exception(exception, root),
        problem != nil do
      problem
    end
  end

  defp stale_exception(%Obligation{target: target} = exception, root) do
    case Target.parse(target || "") do
      {:ok, parsed} ->
        if Target.exists?(parsed, root) do
          nil
        else
          Error.new(
            exception.file,
            exception.line,
            "exception `#{exception.id}` targets #{Target.describe(parsed)}, which no longer exists; " <>
              "retire the exception or point it at the code it now covers"
          )
        end

      {:error, reason} ->
        Error.new(exception.file, exception.line, "exception `#{exception.id}`: #{reason}")
    end
  end

  defp ceilings(contract, root) do
    Enum.flat_map(contract.ceilings, fn %Ceiling{} = ceiling ->
      case Ceiling.count(ceiling, root: root) do
        {:ok, count} when count > ceiling.ceiling ->
          [
            Error.new(
              ceiling.file,
              ceiling.line,
              "scope ceiling `#{ceiling.name}` exceeded: #{count} > #{ceiling.ceiling} (#{Ceiling.describe(ceiling)})"
            )
          ]

        {:ok, _} ->
          []

        {:error, reason} ->
          [
            Error.new(
              ceiling.file,
              ceiling.line,
              "scope ceiling `#{ceiling.name}` cannot be counted: #{reason}"
            )
          ]
      end
    end)
  end
end
