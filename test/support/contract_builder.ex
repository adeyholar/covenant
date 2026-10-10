defmodule Covenant.ContractBuilder do
  @moduledoc """
  Test support: writes throwaway contracts directories and provides valid
  baseline documents that individual tests mutate.
  """

  @fixture_project Path.expand("../fixtures/example_project", __DIR__)

  @doc "The fixture project directory."
  @spec fixture_project() :: Path.t()
  def fixture_project, do: @fixture_project

  @doc "The fixture project's contracts directory."
  @spec fixture_contracts() :: Path.t()
  def fixture_contracts, do: Path.join(@fixture_project, "contracts")

  @doc "Writes `files` (relative path => content) under `dir` and returns `dir`."
  @spec write(Path.t(), %{String.t() => String.t()} | [{String.t(), String.t()}]) :: Path.t()
  def write(dir, files) do
    Enum.each(files, fn {relative, content} ->
      path = Path.join(dir, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    dir
  end

  @doc "Copies the fixture contracts into `dir` (so a test can corrupt its own copy)."
  @spec copy_fixture_contracts(Path.t()) :: Path.t()
  def copy_fixture_contracts(dir) do
    File.mkdir_p!(dir)
    File.cp_r!(fixture_contracts(), dir)
    File.rm(Path.join(dir, "coverage.json"))
    dir
  end

  @doc "A minimal valid heavy-form intent for `demo.widget` with obligations I1 (active) and I2 (retired)."
  @spec heavy_intent() :: String.t()
  def heavy_intent do
    """
    # demo.widget

    ## Purpose

    A widget.

    | Rev | Date | Change | Driver |
    |---|---|---|---|
    | 1 | 2026-10-09 | First | test |

    ## Scope

    Owns widgets.

    ## Environment facts

    - None.

    ## Public surface

    - `Demo.Widget.build(size) :: t` — builds a widget.
    - `Demo.Widget.size/1` — its size.

    ## Invariants

    ### demo.widget.I1 — Widgets have a size
    - **scope:** `Demo.Widget.build/1`
    - **must:** store the size
    - **why:** v1 lost it
    - **kind:** functional
    - **record:** keep-size
    - **status:** active

    ### demo.widget.I2 — Widgets are blue
    - **scope:** `Demo.Widget.build/1`
    - **must:** be blue
    - **why:** branding
    - **kind:** functional
    - **status:** retired

    ## Decisions

    | Decision | Value | Reason | Record |
    |---|---|---|---|
    | Size | kept | lost in v1 | keep-size |

    Worked example: `build(3)` has size 3.

    ## Orderings

    - None.

    ## Known limits

    - None.

    ## Regeneration brief

    Rebuild from this intent and the tests.
    """
  end

  @doc "A minimal valid light-form obligations file for `demo.gadget` with I1 (active) and an exception I2."
  @spec light_obligations(String.t()) :: String.t()
  def light_obligations(target \\ "Covenant.Error.format/1") do
    """
    # demo.gadget

    ## Purpose

    A gadget.

    ### demo.gadget.I1 — Gadgets beep
    - **scope:** `Demo.Gadget.beep/0`
    - **must:** return `:beep`
    - **kind:** functional
    - **status:** active

    ### demo.gadget.I2 — The gadget keeps its own formatter
    - **scope:** `#{target}`
    - **must:** keep a private copy
    - **kind:** exception
    - **target:** `#{target}`
    - **status:** active
    """
  end

  @doc "Valid records for `demo.widget`."
  @spec widget_records() :: String.t()
  def widget_records do
    """
    - id: keep-size
      date: "2026-10-09"
      decision: The size is stored.
      driver: v1 lost it.
      invariant: demo.widget.I1
      approved_by: lead
      conditions:
        - text: Elixir is modern
          check: { kind: elixir, version: ">= 1.0.0" }
    """
  end

  @doc "A complete, valid demo contracts directory written under `dir`."
  @spec demo_contracts(Path.t()) :: Path.t()
  def demo_contracts(dir) do
    write(dir, %{
      "demo/widget.intent.md" => heavy_intent(),
      "demo/widget.decisions.yml" => widget_records(),
      "demo/gadget.obligations.md" => light_obligations()
    })
  end
end
