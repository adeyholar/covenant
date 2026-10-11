defmodule Covenant.Contract.MarkdownContractTest do
  use Covenant.Case, component: "covenant.contract", async: true

  alias Covenant.ContractBuilder
  alias Covenant.Contract.{Component, Obligation}
  alias Covenant.Error
  alias Covenant.Parser.Markdown

  @path "demo/widget.intent.md"

  defp parse(text, form \\ :heavy, id \\ "demo.widget"), do: Markdown.parse(text, @path, id, form)

  defp messages({:error, errors}), do: Enum.map(errors, &Error.format/1)

  describe "heavy form" do
    @tag obligation: "covenant.contract.I2"
    test "parses the baseline intent into a component with obligations and sections" do
      assert {:ok, %Component{} = component} = parse(ContractBuilder.heavy_intent())
      assert component.id == "demo.widget"
      assert component.app == "demo"
      assert component.name == "widget"
      assert component.form == :heavy
      assert component.purpose == "A widget."
      assert Enum.map(component.sections, & &1.title) == Markdown.heavy_sections()

      assert [%Obligation{id: "demo.widget.I1"} = i1, %Obligation{id: "demo.widget.I2"} = i2] =
               component.obligations

      assert i1.title == "Widgets have a size"
      assert i1.scope == "`Demo.Widget.build/1`"
      assert i1.must == "store the size"
      assert i1.why == "v1 lost it"
      assert i1.kind == :functional
      assert i1.record == "keep-size"
      assert i1.status == :active
      assert i1.file == @path
      assert i1.line == 26
      assert i2.status == :retired
      assert i2.record == nil
    end

    @tag obligation: "covenant.contract.I3"
    test "reports a missing required field at the block's line" do
      text = String.replace(ContractBuilder.heavy_intent(), "- **must:** store the size\n", "")

      assert messages(parse(text)) == [
               "demo/widget.intent.md:26: obligation `demo.widget.I1` is missing `must`"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "requires why in heavy form only" do
      text = String.replace(ContractBuilder.heavy_intent(), "- **why:** v1 lost it\n", "")

      assert messages(parse(text)) == [
               "demo/widget.intent.md:26: obligation `demo.widget.I1` is missing `why`"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "reports an empty field at the field's line" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "- **must:** store the size",
          "- **must:**"
        )

      assert messages(parse(text)) == [
               "demo/widget.intent.md:28: obligation `demo.widget.I1` has an empty `must`"
             ]
    end

    @tag obligation: "covenant.contract.I4"
    test "rejects an unknown kind and an unknown status at their lines" do
      text =
        ContractBuilder.heavy_intent()
        |> String.replace(
          "- **kind:** functional\n- **record:** keep-size",
          "- **kind:** magical\n- **record:** keep-size"
        )
        |> String.replace("- **status:** retired", "- **status:** sleeping")

      assert messages(parse(text)) == [
               "demo/widget.intent.md:30: obligation `demo.widget.I1` has unknown kind `magical` (expected one of: exception, functional, non-functional, ordering, persisted-format, security)",
               "demo/widget.intent.md:39: obligation `demo.widget.I2` has unknown status `sleeping` (expected one of: active, retired)"
             ]
    end

    @tag obligation: "covenant.contract.I4"
    test "rejects an obligation id that does not belong to the component" do
      text =
        String.replace(ContractBuilder.heavy_intent(), "### demo.widget.I2", "### demo.other.I2")

      assert messages(parse(text)) == [
               "demo/widget.intent.md:34: obligation id `demo.other.I2` must be `demo.widget.I<n>`"
             ]
    end

    @tag obligation: "covenant.contract.I4"
    test "rejects a duplicated obligation id" do
      text =
        String.replace(ContractBuilder.heavy_intent(), "### demo.widget.I2", "### demo.widget.I1")

      assert messages(parse(text)) == [
               "demo/widget.intent.md:34: obligation `demo.widget.I1` is declared twice (first at line 26)"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "rejects a block whose heading is not `### <id> — <title>`" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "### demo.widget.I2 — Widgets are blue",
          "### Widgets are blue"
        )

      assert messages(parse(text)) == [
               "demo/widget.intent.md:34: obligation heading must be `### demo.widget.I<n> — <title>`"
             ]
    end

    @tag obligation: "covenant.contract.I2"
    test "accepts a plain hyphen between id and title" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "### demo.widget.I2 — Widgets are blue",
          "### demo.widget.I2 - Widgets are blue"
        )

      assert {:ok, component} = parse(text)

      assert Enum.map(component.obligations, & &1.title) == [
               "Widgets have a size",
               "Widgets are blue"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "an exception block needs a target" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "- **kind:** functional\n- **status:** retired",
          "- **kind:** exception\n- **status:** retired"
        )

      assert messages(parse(text)) == [
               "demo/widget.intent.md:34: obligation `demo.widget.I2` is `kind: exception` but has no `target` naming the code it covers"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "reports a missing required section where it should appear" do
      text = String.replace(ContractBuilder.heavy_intent(), "## Orderings\n\n- None.\n\n", "")

      assert messages(parse(text)) == [
               "demo/widget.intent.md:49: missing required section `## Orderings` (heavy form)"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "reports a missing final section at the end of the file" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "## Regeneration brief\n\nRebuild from this intent and the tests.\n",
          ""
        )

      assert [message] = messages(parse(text))

      assert message =~
               ~r/^demo\/widget.intent.md:\d+: missing required section `## Regeneration brief` \(heavy form\)$/
    end

    @tag obligation: "covenant.contract.I3"
    test "reports sections out of order" do
      text =
        ContractBuilder.heavy_intent()
        |> String.replace("## Scope\n\nOwns widgets.\n\n", "")
        |> String.replace(
          "## Known limits\n\n- None.\n\n",
          "## Known limits\n\n- None.\n\n## Scope\n\nOwns widgets.\n\n"
        )

      assert messages(parse(text)) == [
               "demo/widget.intent.md:53: section `## Scope` must come before `## Known limits` (heavy form)"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "rejects a duplicated section" do
      text = ContractBuilder.heavy_intent() <> "\n## Scope\n\nAgain.\n"

      assert messages(parse(text)) == [
               "demo/widget.intent.md:61: section `## Scope` is declared twice (first at line 11)",
               "demo/widget.intent.md:61: section `## Scope` must come before `## Regeneration brief` (heavy form)"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "requires the revision log table in Purpose" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "| Rev | Date | Change | Driver |",
          "| Revision | When |"
        )

      assert messages(parse(text)) == [
               "demo/widget.intent.md:3: section `## Purpose` lacks the revision log table `| Rev | Date | Change | Driver |` (heavy form)"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "rejects an empty Purpose" do
      text =
        Regex.replace(
          ~r/## Purpose\n\n.*?\n\n## Scope/s,
          ContractBuilder.heavy_intent(),
          "## Purpose\n\n## Scope"
        )

      assert messages(parse(text)) == ["demo/widget.intent.md:3: section `## Purpose` is empty"]
    end

    @tag obligation: "covenant.contract.I2"
    test "ignores headings and field lines inside fenced code blocks" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "## Orderings\n\n- None.\n",
          "## Orderings\n\n```markdown\n## Not a section\n### demo.widget.I9 — Not a block\n- **must:** nothing\n```\n\n- None.\n"
        )

      assert {:ok, component} = parse(text)
      assert Enum.map(component.obligations, & &1.id) == ["demo.widget.I1", "demo.widget.I2"]
      refute Enum.any?(component.sections, &(&1.title == "Not a section"))
    end

    @tag obligation: "covenant.contract.I2"
    test "joins indented continuation lines into the field above" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "- **must:** store the size\n",
          "- **must:** store the size\n  and never lose it\n  across rebuilds\n"
        )

      assert {:ok, component} = parse(text)
      assert hd(component.obligations).must == "store the size and never lose it across rebuilds"
    end

    @tag obligation: "covenant.contract.I2"
    test "keeps unknown fields and strips backticks from record and target" do
      text =
        String.replace(
          ContractBuilder.heavy_intent(),
          "- **record:** keep-size\n",
          "- **record:** `keep-size`\n- **owner:** team-a\n"
        )

      assert {:ok, component} = parse(text)
      assert hd(component.obligations).record == "keep-size"
      assert hd(component.obligations).fields["owner"] == "team-a"
    end

    @tag obligation: "covenant.contract.I7"
    test "collects several problems at once" do
      text =
        ContractBuilder.heavy_intent()
        |> String.replace("- **must:** store the size\n", "")
        |> String.replace("## Orderings\n\n- None.\n\n", "")

      assert length(messages(parse(text))) == 2
    end
  end

  describe "light form" do
    @tag obligation: "covenant.contract.I2"
    test "parses obligations anywhere after Purpose, including exception blocks" do
      assert {:ok, component} = parse(ContractBuilder.light_obligations(), :light, "demo.gadget")
      assert component.form == :light
      assert component.purpose == "A gadget."
      assert [i1, i2] = component.obligations
      assert i1.why == nil
      assert i2.kind == :exception
      assert i2.target == "Covenant.Error.format/1"
      assert Component.testable_obligations(component) == [i1]
      assert Component.exceptions(component) == [i2]
    end

    @tag obligation: "covenant.contract.I3"
    test "requires only Purpose" do
      text = String.replace(ContractBuilder.light_obligations(), "## Purpose\n\nA gadget.\n", "")

      assert messages(parse(text, :light, "demo.gadget")) == [
               "demo/widget.intent.md:15: missing required section `## Purpose` (light form)"
             ]
    end

    @tag obligation: "covenant.contract.I3"
    test "does not require why" do
      assert {:ok, _} = parse(ContractBuilder.light_obligations(), :light, "demo.gadget")
    end
  end

  describe "system form" do
    @tag obligation: "covenant.contract.I2"
    test "requires no sections and reads obligations under any heading" do
      text = """
      # system

      ## Cross-cutting invariants

      ### system.I1 — Every row carries a tenant id
      - **scope:** every table
      - **must:** carry `tenant_id`
      - **kind:** security
      - **status:** active
      """

      assert {:ok, component} = parse(text, :system, "system")
      assert component.app == "system"
      assert component.name == "system"
      assert [%Obligation{id: "system.I1", kind: :security}] = component.obligations
    end
  end

  describe "malformed obligation blocks are rejected, never skipped" do
    defp intent, do: ContractBuilder.heavy_intent()

    @tag obligation: "covenant.contract.I10"
    test "an id-shaped heading at the wrong level is an error" do
      text = String.replace(intent(), "### demo.widget.I2", "#### demo.widget.I2")

      assert messages(parse(text)) == [
               "demo/widget.intent.md:34: obligation heading `demo.widget.I2` must be a `###` heading, found `####`"
             ]
    end

    @tag obligation: "covenant.contract.I10"
    test "an obligation heading indented by one to three spaces is an error" do
      for indent <- [" ", "  ", "   "] do
        text = String.replace(intent(), "### demo.widget.I2", indent <> "### demo.widget.I2")

        assert messages(parse(text)) == [
                 "demo/widget.intent.md:34: obligation heading `demo.widget.I2` must start in column 1"
               ]
      end
    end

    @tag obligation: "covenant.contract.I10"
    test "an indented block's fields are not merged into the block above" do
      text =
        intent()
        |> String.replace("### demo.widget.I2", "  ### I2")
        |> String.replace("- **status:** retired", "- **status:** active")

      assert Enum.any?(messages(parse(text)), &(&1 =~ ":34: obligation heading `I2`"))
    end

    @tag obligation: "covenant.contract.I10"
    test "a code fence that is never closed is an error at its opening line" do
      text = String.replace(intent(), "## Decisions\n", "## Decisions\n\n```\n")

      assert "demo/widget.intent.md:43: code fence opened here is never closed" in messages(
               parse(text)
             )
    end

    @tag obligation: "covenant.contract.I10"
    test "a fence closes only with the same character and at least the same length" do
      longer =
        String.replace(
          intent(),
          "## Orderings\n",
          "## Orderings\n\n````\n```\n## Not a section\n````\n"
        )

      assert {:ok, component} = parse(longer)
      refute Enum.any?(component.sections, &(&1.title == "Not a section"))

      mixed =
        String.replace(
          intent(),
          "## Orderings\n",
          "## Orderings\n\n```\n~~~\n## Not a section\n```\n"
        )

      assert {:ok, component} = parse(mixed)
      refute Enum.any?(component.sections, &(&1.title == "Not a section"))
    end

    @tag obligation: "covenant.contract.I10"
    test "a field line outside any obligation block is an error" do
      text = String.replace(intent(), "## Decisions\n", "## Decisions\n\n- **status:** retired\n")

      assert [message] = messages(parse(text))

      assert message =~
               ~r/^demo\/widget.intent.md:\d+: field `status` is outside an obligation block$/
    end

    @tag obligation: "covenant.contract.I10"
    test "a field repeated in one block is an error at the repeat" do
      text =
        String.replace(
          intent(),
          "- **status:** retired",
          "- **status:** active\n- **status:** retired"
        )

      assert messages(parse(text)) == [
               "demo/widget.intent.md:40: obligation `demo.widget.I2` repeats `status` (first at line 39)"
             ]
    end

    @tag obligation: "covenant.contract.I2"
    test "a leading byte-order mark does not hide the front matter" do
      text = "\uFEFF---\nmodules: [Demo.Widget]\n---\n" <> intent()

      assert {:ok, component} = parse(text)
      assert component.meta == %{"modules" => ["Demo.Widget"]}
    end
  end

  @tag obligation: "covenant.contract.I7"
  test "parse_file reports an unreadable file" do
    assert {:error, [%Error{file: "nope/missing.intent.md", line: nil, message: message}]} =
             Markdown.parse_file("nope/missing.intent.md", "nope.missing", :heavy)

    assert message =~ "cannot read file"
  end
end
