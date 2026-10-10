defmodule Mix.Tasks.Covenant.Regen do
  @shortdoc "Writes a regeneration pack for a component"

  @moduledoc """
  Writes everything a fresh agent needs to rebuild a component from its
  Contract, with the implementation excluded (IMP R17, the fire drill).

      mix covenant.regen example.counter
      mix covenant.regen example.counter --out tmp/regen/counter
      mix covenant.regen example.counter --contracts path

  The pack holds the intent (or obligations file), the decision records, the
  system intent and records, the component's contract tests, public-surface
  stubs, the regeneration brief and a `PROMPT.md` for the regenerating agent.
  See `Covenant.Regen` for the layout. Contract tests keep their path relative
  to the directory that holds the contracts directory.

  A Public surface reference to a module the component does not own (see
  `Covenant.Regen.Ownership`: the intent's `#### Modules` paragraph or `modules:`
  front matter, else where the module lives) gets no stub; the task says how
  many it skipped. A module it could not place is stubbed anyway and listed on a
  `possibly_foreign:` line.

  ## Options

  * `--out DIR` — the pack directory (default `tmp/covenant/regen/<component>`);
  * `--contracts DIR` — the contracts directory;
  * `--test-path PATH` — a contract test path or glob to search, relative to the
    current directory or absolute (repeatable).
  """

  use Mix.Task

  alias Covenant.{Contract, Error, Regen}

  @requirements ["app.config"]

  @switches [out: :string, contracts: :string, test_path: :keep]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}; see `mix help covenant.regen`")
    end

    component_id =
      case positional do
        [id] -> id
        _ -> Mix.raise("usage: mix covenant.regen <component id> [--out DIR]")
      end

    contracts_dir = opts[:contracts] || Covenant.contracts_dir()

    test_paths =
      Keyword.get_values(opts, :test_path)
      |> then(&if(&1 == [], do: Covenant.test_paths(), else: &1))
      |> Enum.map(&Path.expand/1)

    contract =
      case Contract.load(contracts_dir) do
        {:ok, contract} ->
          contract

        {:error, errors} ->
          Enum.each(Error.sort(errors), &Mix.shell().error(Error.format(&1)))
          Mix.raise("the Contract in #{contracts_dir} could not be parsed")
      end

    regen_opts = [test_paths: test_paths] ++ if(opts[:out], do: [out: opts[:out]], else: [])

    case Regen.write_pack(contract, component_id, regen_opts) do
      {:ok, %{dir: dir, files: files, skipped: skipped, possibly_foreign: possibly_foreign}} ->
        Enum.each(files, &Mix.shell().info("  #{Path.relative_to(&1, dir)}"))

        if skipped != [] do
          modules = skipped |> Enum.map(& &1.module) |> Enum.uniq() |> Enum.sort()

          Mix.shell().info(
            "covenant.regen: skipped #{length(skipped)} references to modules the component does not own: " <>
              Enum.join(modules, ", ")
          )
        end

        if possibly_foreign != [] do
          Mix.shell().info(
            "covenant.regen: possibly_foreign: #{Enum.join(possibly_foreign, ", ")} " <>
              "(stubbed; list the component's modules under `#### Modules` or `modules:` to settle it)"
          )
        end

        Mix.shell().info("covenant.regen: wrote #{length(files)} file(s) to #{dir}")
        :ok

      {:error, reason} ->
        Mix.raise(reason)
    end
  end
end
