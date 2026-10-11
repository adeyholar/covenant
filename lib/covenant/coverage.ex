defmodule Covenant.Coverage do
  @moduledoc """
  Contract coverage: the share of active obligations with at least one
  passing tagged test, per component, per app and overall.

  Retired obligations and `kind: exception` declarations are reported but
  excluded from the denominators.

  Static coverage (`compute(contract, results, covered: :tagged)`, used by
  `mix covenant.check --static`) counts an obligation as covered when at
  least one test is tagged with it, run or not; its JSON carries
  `"mode": "static"` so it is never mistaken for a passing run.
  """

  alias Covenant.Contract
  alias Covenant.Contract.Obligation
  alias Covenant.Results

  @type stats :: %{active: non_neg_integer(), covered: non_neg_integer(), ratio: float() | nil}

  @type obligation_entry :: %{
          status: Obligation.status(),
          kind: Obligation.kind(),
          testable: boolean(),
          passing: non_neg_integer(),
          failing: non_neg_integer(),
          tests: [String.t()]
        }

  @type component_entry :: %{
          form: Contract.Component.form(),
          app: String.t(),
          active: non_neg_integer(),
          covered: non_neg_integer(),
          ratio: float() | nil,
          obligations: %{String.t() => obligation_entry()}
        }

  @type t :: %__MODULE__{
          totals: stats(),
          apps: %{String.t() => stats()},
          components: %{String.t() => component_entry()},
          mode: :run | :static
        }

  defstruct totals: %{active: 0, covered: 0, ratio: nil}, apps: %{}, components: %{}, mode: :run

  @doc """
  Computes coverage from the Contract and a test run. Options:

  * `:covered` — `:passing` (default): an obligation is covered by a passing
    test; `:tagged`: by any tagged test (static mode).
  """
  @spec compute(Contract.t(), Results.t(), keyword()) :: t()
  def compute(%Contract{} = contract, %Results{} = results, opts \\ []) do
    by_obligation = Results.by_obligation(results)
    tagged? = Keyword.get(opts, :covered, :passing) == :tagged

    components =
      Map.new(contract.components, fn {id, component} ->
        obligations =
          Map.new(component.obligations, fn obligation ->
            tests = Map.get(by_obligation, obligation.id, [])

            {obligation.id,
             %{
               status: obligation.status,
               kind: obligation.kind,
               testable: Obligation.testable?(obligation),
               passing: Enum.count(tests, &(&1.state == :passed)),
               failing: Enum.count(tests, &(&1.state == :failed)),
               tests: tests |> Enum.map(& &1.name) |> Enum.sort()
             }}
          end)

        testable = obligations |> Map.values() |> Enum.filter(& &1.testable)
        active = length(testable)
        covered = Enum.count(testable, &if(tagged?, do: &1.tests != [], else: &1.passing > 0))

        {id,
         %{
           form: component.form,
           app: component.app,
           active: active,
           covered: covered,
           ratio: ratio(covered, active),
           obligations: obligations
         }}
      end)

    apps =
      components
      |> Map.values()
      |> Enum.group_by(& &1.app)
      |> Map.new(fn {app, entries} -> {app, sum(entries)} end)

    %__MODULE__{
      totals: sum(Map.values(components)),
      apps: apps,
      components: components,
      mode: if(tagged?, do: :static, else: :run)
    }
  end

  defp sum(entries) do
    active = entries |> Enum.map(& &1.active) |> Enum.sum()
    covered = entries |> Enum.map(& &1.covered) |> Enum.sum()
    %{active: active, covered: covered, ratio: ratio(covered, active)}
  end

  defp ratio(_covered, 0), do: nil
  defp ratio(covered, active), do: Float.round(covered / active, 4)

  @doc "The JSON-ready map written to `contracts/coverage.json`."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = coverage) do
    mode = if coverage.mode == :static, do: %{"mode" => "static"}, else: %{}

    Map.merge(mode, %{
      "covenant" => Covenant.version(),
      "totals" => stats_map(coverage.totals),
      "apps" => Map.new(coverage.apps, fn {app, stats} -> {app, stats_map(stats)} end),
      "components" =>
        Map.new(coverage.components, fn {id, entry} ->
          {id,
           %{
             "form" => Atom.to_string(entry.form),
             "app" => entry.app,
             "active" => entry.active,
             "covered" => entry.covered,
             "coverage" => entry.ratio,
             "obligations" =>
               Map.new(entry.obligations, fn {oid, o} ->
                 {oid,
                  %{
                    "status" => Atom.to_string(o.status),
                    "kind" => Atom.to_string(o.kind),
                    "testable" => o.testable,
                    "passing" => o.passing,
                    "failing" => o.failing,
                    "tests" => o.tests
                  }}
               end)
           }}
        end)
    })
  end

  defp stats_map(stats),
    do: %{"active" => stats.active, "covered" => stats.covered, "coverage" => stats.ratio}

  @doc "Renders the per-component and per-app coverage table."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = coverage) do
    rows =
      coverage.components
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, entry} -> {id, entry} end)

    apps = coverage.apps |> Enum.sort_by(fn {app, _} -> app end)

    width =
      [
        8
        | Enum.map(rows, fn {id, _} -> String.length(id) end) ++
            Enum.map(apps, fn {app, _} -> String.length(app) end)
      ]
      |> Enum.max()

    title =
      case coverage.mode do
        :static ->
          "Static contract coverage (obligations with a tagged test / active obligations)"

        :run ->
          "Contract coverage (obligations with a passing test / active obligations)"
      end

    lines =
      [title, ""] ++
        Enum.map(rows, fn {id, entry} -> row(id, entry, width) end) ++
        [""] ++
        Enum.map(apps, fn {app, stats} -> row("app " <> app, stats, width + 4) end) ++
        ["", row("total", coverage.totals, width + 4)]

    Enum.join(lines, "\n")
  end

  defp row(label, stats, width) do
    percent =
      case stats.ratio do
        nil -> "   n/a"
        ratio -> :io_lib.format("~5.1f%", [ratio * 100]) |> IO.iodata_to_binary()
      end

    "  #{String.pad_trailing(label, width)}  #{String.pad_leading("#{stats.covered}/#{stats.active}", 7)}  #{percent}"
  end
end
