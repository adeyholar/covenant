defmodule Covenant.ConditionsContractTest do
  use Covenant.Case, component: "covenant.conditions", async: true

  alias Covenant.{Conditions, Contract}
  alias Covenant.Conditions.Context
  alias Covenant.Contract.{Ceiling, Condition}
  alias Covenant.ContractBuilder

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "present.txt"), "")

    ctx = %Context{
      root: dir,
      lock: %{"postgrex" => "0.20.1", "from_git" => nil},
      env: %{"DATABASE_URL" => "postgres://x"},
      elixir_version: "1.19.6",
      otp_version: "28.5"
    }

    {:ok, ctx: ctx}
  end

  defp premise(check), do: %Condition{text: "premise", check: check}

  @tag obligation: "covenant.conditions.I2"
  test "a condition without a check is unchecked", %{ctx: ctx} do
    assert Conditions.evaluate(premise(nil), ctx) == :unchecked
  end

  @tag obligation: "covenant.conditions.I1"
  test "dep: present, present with a matching or failing requirement, missing, unversioned", %{
    ctx: ctx
  } do
    assert {:ok, "dependency `postgrex` is locked at 0.20.1"} =
             Conditions.evaluate(premise(%{"kind" => "dep", "name" => "postgrex"}), ctx)

    assert {:ok, _} =
             Conditions.evaluate(
               premise(%{"kind" => "dep", "name" => "postgrex", "version" => "~> 0.20"}),
               ctx
             )

    assert {:suspect, "dependency `postgrex` is 0.20.1, which does not match `~> 0.21`"} =
             Conditions.evaluate(
               premise(%{"kind" => "dep", "name" => "postgrex", "version" => "~> 0.21"}),
               ctx
             )

    assert {:suspect, "dependency `ecto` is not in mix.lock"} =
             Conditions.evaluate(premise(%{"kind" => "dep", "name" => "ecto"}), ctx)

    assert {:ok, "dependency `from_git` is locked"} =
             Conditions.evaluate(premise(%{"kind" => "dep", "name" => "from_git"}), ctx)

    assert {:suspect, "dependency `from_git` has no version to compare with `~> 1.0`"} =
             Conditions.evaluate(
               premise(%{"kind" => "dep", "name" => "from_git", "version" => "~> 1.0"}),
               ctx
             )

    assert {:suspect, "`banana` is not a valid version requirement"} =
             Conditions.evaluate(
               premise(%{"kind" => "dep", "name" => "postgrex", "version" => "banana"}),
               ctx
             )
  end

  @tag obligation: "covenant.conditions.I1"
  test "env: set or not", %{ctx: ctx} do
    assert {:ok, "env `DATABASE_URL` is set"} =
             Conditions.evaluate(premise(%{"kind" => "env", "name" => "DATABASE_URL"}), ctx)

    assert {:suspect, "env `SECRET` is not set"} =
             Conditions.evaluate(premise(%{"kind" => "env", "name" => "SECRET"}), ctx)
  end

  @tag obligation: "covenant.conditions.I1"
  test "file: exists or not, relative to the root", %{ctx: ctx} do
    assert {:ok, "file `present.txt` exists"} =
             Conditions.evaluate(premise(%{"kind" => "file", "path" => "present.txt"}), ctx)

    assert {:suspect, "file `gone.txt` does not exist"} =
             Conditions.evaluate(premise(%{"kind" => "file", "path" => "gone.txt"}), ctx)
  end

  @tag obligation: "covenant.conditions.I1"
  test "otp and elixir version requirements, with short OTP versions normalised", %{ctx: ctx} do
    assert {:ok, "OTP 28.5 matches `>= 26.0.0`"} =
             Conditions.evaluate(premise(%{"kind" => "otp", "version" => ">= 26.0.0"}), ctx)

    assert {:ok, _} =
             Conditions.evaluate(premise(%{"kind" => "otp", "version" => "~> 28.0"}), %{
               ctx
               | otp_version: "28"
             })

    assert {:suspect, "OTP is 28.5, which does not match `~> 27.0`"} =
             Conditions.evaluate(premise(%{"kind" => "otp", "version" => "~> 27.0"}), ctx)

    assert {:ok, _} =
             Conditions.evaluate(premise(%{"kind" => "elixir", "version" => "~> 1.19"}), ctx)

    assert {:suspect, "Elixir is 1.19.6, which does not match `~> 1.20`"} =
             Conditions.evaluate(premise(%{"kind" => "elixir", "version" => "~> 1.20"}), ctx)
  end

  @tag obligation: "covenant.conditions.I1"
  test "a requirement may leave out the minor and patch numbers after a comparison operator", %{
    ctx: ctx
  } do
    otp = fn req, version ->
      Conditions.evaluate(premise(%{"kind" => "otp", "version" => req}), %{
        ctx
        | otp_version: version
      })
    end

    assert {:ok, "OTP 28.5 matches `>= 28.0`"} = otp.(">= 28.0", "28.5")
    assert {:ok, "OTP 28 matches `>= 28`"} = otp.(">= 28", "28")
    assert {:ok, _} = otp.(">=28.0", "28.5")
    assert {:ok, _} = otp.(">= 28.5", "28.5")
    assert {:suspect, "OTP is 28.5, which does not match `>= 28.6`"} = otp.(">= 28.6", "28.5")
    assert {:suspect, "OTP is 28.5, which does not match `> 28.5`"} = otp.("> 28.5", "28.5")
    assert {:ok, _} = otp.("> 28.4", "28.5")
    assert {:ok, _} = otp.("<= 28.5", "28.5")
    assert {:suspect, _} = otp.("< 28.5", "28.5")
    assert {:ok, _} = otp.("== 28.5", "28.5")
    assert {:ok, _} = otp.(">= 28.0 and < 29", "28.5")
    assert {:suspect, _} = otp.(">= 28.0 and < 28.5", "28.5")
    assert {:ok, _} = otp.("< 28 or >= 28.5", "28.5")

    # complete versions are left as they are, a pre-release stays a pre-release
    assert {:ok, _} = otp.(">= 28.0.0", "28.5")
    assert {:suspect, _} = otp.(">= 28.0.1", "28.0.0")
    assert {:ok, _} = otp.(">= 1.0.0-rc.1", "1.0.0")
    assert {:ok, _} = otp.("== 1.0.0-rc.1", "1.0.0-rc.1")

    # `~>` keeps the parts it was written with: `~> 28.0` is below 29, `~> 28.0.0` is below 28.1
    assert {:ok, _} = otp.("~> 28.0", "28.5")
    assert {:suspect, _} = otp.("~> 28.0.0", "28.5")

    # a fourth number (OTP patch releases) is dropped, short versions are padded
    assert {:ok, "OTP 27.3.4.1 matches `>= 27.3`"} = otp.(">= 27.3", "27.3.4.1")
    assert {:suspect, _} = otp.(">= 27.4", "27.3.4.1")
    assert {:ok, _} = otp.(">= 27.3.4", "27.3.4.1")
    assert {:suspect, _} = otp.(">= 27.3.5", "27.3.4.1")
    assert {:ok, _} = otp.(">= 28.0.1", "28.0.1")
    assert {:suspect, _} = otp.(">= 28.0.2", "28.0.1")
    assert {:ok, _} = otp.(">= 28.0.0", "28")
    assert {:suspect, _} = otp.(">= 28.0.1", "28")
  end

  @tag obligation: "covenant.conditions.I2"
  test "a requirement that cannot be parsed and a version that cannot be compared are suspect", %{
    ctx: ctx
  } do
    otp = fn req, version ->
      Conditions.evaluate(premise(%{"kind" => "otp", "version" => req}), %{
        ctx
        | otp_version: version
      })
    end

    for req <- ["banana", ">=", ">= x", "~> 28", "28.0", "", ">= 28.0 &&"] do
      assert {:suspect, "`" <> _ = reason} = otp.(req, "28.5"), "requirement #{inspect(req)}"
      assert reason == "`#{req}` is not a valid version requirement"
    end

    assert {:suspect, "OTP version `28.0-rc2` cannot be compared with `>= 28.0`"} =
             otp.(">= 28.0", "28.0-rc2")

    assert {:suspect, "OTP version `x` cannot be compared with `>= 28.0`"} =
             otp.(">= 28.0", "x")
  end

  @tag obligation: "covenant.conditions.I2"
  test "unknown or incomplete checks are suspect, never silently ok", %{ctx: ctx} do
    assert {:suspect,
            "unknown check kind `weather` (expected dep, env, file, otp, elixir or value)"} =
             Conditions.evaluate(premise(%{"kind" => "weather"}), ctx)

    assert {:suspect, "check `env` is incomplete: " <> _} =
             Conditions.evaluate(premise(%{"kind" => "env"}), ctx)

    assert {:suspect, "malformed check " <> _} = Conditions.evaluate(premise("yes"), ctx)

    # only the kind selects the evaluation: another kind's fields never rescue a check
    foreign = %{"name" => "DATABASE_URL", "path" => "present.txt", "version" => ">= 0.0.0"}

    assert {:suspect, "unknown check kind `weather` " <> _} =
             Conditions.evaluate(premise(Map.put(foreign, "kind", "weather")), ctx)

    for {kind, own} <- [
          {"env", "name"},
          {"file", "path"},
          {"otp", "version"},
          {"elixir", "version"},
          {"value", "call"}
        ] do
      check = foreign |> Map.delete(own) |> Map.put("kind", kind)

      assert {:suspect, reason} = Conditions.evaluate(premise(check), ctx)
      assert String.starts_with?(reason, "check `#{kind}` is incomplete: "), reason
    end
  end

  @limits "Covenant.ExampleLimits.limits/0"

  defp value(call, equals, path \\ nil) do
    check = %{"kind" => "value", "call" => call, "equals" => equals}
    premise(if path, do: Map.put(check, "path", path), else: check)
  end

  @tag obligation: "covenant.conditions.I6"
  test "value: a value that equals the record holds, and the outcome says what was found", %{
    ctx: ctx
  } do
    assert {:ok, "Covenant.ExampleLimits.limits/0 [claim_batch] is 20"} =
             Conditions.evaluate(value(@limits, 20, ["claim_batch"]), ctx)

    assert {:ok, "Covenant.ExampleLimits.answer/0 is 42"} =
             Conditions.evaluate(value("Covenant.ExampleLimits.answer/0", 42), ctx)

    assert {:ok, _} = Conditions.evaluate(value("Covenant.ExampleLimits.ready?/0", true), ctx)

    # YAML says `chat` where the code returns :chat; a list compares element by element,
    # nil and booleans are themselves, and a number compares by value
    for {path, equals} <- [
          {["mode"], "fast"},
          {["backoff_s"], [60, 300]},
          {["enabled"], true},
          {["disabled"], false},
          {["nothing"], nil},
          {["ratio"], 0.5},
          {["claim_batch"], 20.0},
          {["name"], "invoices"}
        ] do
      assert {:ok, _} = Conditions.evaluate(value(@limits, equals, path), ctx),
             "path #{inspect(path)} equals #{inspect(equals)}"
    end

    assert {:ok, "Covenant.ExampleLimits.limits/0 [nested, deep, depth] is 3"} =
             Conditions.evaluate(value(@limits, 3, ["nested", "deep", "depth"]), ctx)

    # path keys: atoms work too, the atom key is tried before the string key, a string key is found
    assert {:ok, _} = Conditions.evaluate(value(@limits, 20, [:claim_batch]), ctx)
    assert {:ok, _} = Conditions.evaluate(value(@limits, 1, [:dup]), ctx)
    assert {:ok, _} = Conditions.evaluate(value(@limits, 1, ["dup"]), ctx)
    assert {:suspect, _} = Conditions.evaluate(value(@limits, 2, ["dup"]), ctx)
    assert {:ok, _} = Conditions.evaluate(value(@limits, 7, ["stringy"]), ctx)
    assert {:ok, _} = Conditions.evaluate(value(@limits, 7, [:stringy]), ctx)

    # an empty path is no path
    assert {:ok, "Covenant.ExampleLimits.answer/0 is 42"} =
             Conditions.evaluate(value("Covenant.ExampleLimits.answer/0", 42, []), ctx)
  end

  @tag obligation: "covenant.conditions.I6"
  test "value: a different value, a missing key or a non-map is suspect, naming what was found",
       %{ctx: ctx} do
    assert {:suspect, "Covenant.ExampleLimits.limits/0 [claim_batch] is 20, the record says 21"} =
             Conditions.evaluate(value(@limits, 21, ["claim_batch"]), ctx)

    assert {:suspect, "Covenant.ExampleLimits.answer/0 is 42, the record says 43"} =
             Conditions.evaluate(value("Covenant.ExampleLimits.answer/0", 43), ctx)

    assert {:suspect,
            "Covenant.ExampleLimits.limits/0 [backoff_s] is [60, 300], the record says [60, 301]"} =
             Conditions.evaluate(value(@limits, [60, 301], ["backoff_s"]), ctx)

    assert {:suspect,
            "Covenant.ExampleLimits.limits/0 [nested, deep, depth] is 3, the record says 4"} =
             Conditions.evaluate(value(@limits, 4, ["nested", "deep", "depth"]), ctx)

    assert {:suspect, "Covenant.ExampleLimits.limits/0 [mode] is :fast, the record says \"slow\""} =
             Conditions.evaluate(value(@limits, "slow", ["mode"]), ctx)

    # a boolean is not its string, a number is not its string, and the list order matters
    for {path, equals} <- [
          {["enabled"], "true"},
          {["enabled"], false},
          {["enabled"], nil},
          {["disabled"], true},
          {["disabled"], nil},
          {["nothing"], false},
          {["nothing"], "nil"},
          {["claim_batch"], "20"},
          {["backoff_s"], [300, 60]}
        ] do
      assert {:suspect, _} = Conditions.evaluate(value(@limits, equals, path), ctx),
             "path #{inspect(path)} equals #{inspect(equals)}"
    end

    assert {:suspect, "Covenant.ExampleLimits.limits/0 [nope] has no key `nope`"} =
             Conditions.evaluate(value(@limits, 1, ["nope"]), ctx)

    assert {:suspect, "Covenant.ExampleLimits.limits/0 [nested, nope, depth] has no key `nope`"} =
             Conditions.evaluate(value(@limits, 1, ["nested", "nope", "depth"]), ctx)

    # the path walks into a number: nothing to find there
    assert {:suspect, "Covenant.ExampleLimits.limits/0 [claim_batch, x] has no key `x`"} =
             Conditions.evaluate(value(@limits, 1, ["claim_batch", "x"]), ctx)

    # a result that is not a map has no key either
    assert {:suspect, "Covenant.ExampleLimits.answer/0 [x] has no key `x`"} =
             Conditions.evaluate(value("Covenant.ExampleLimits.answer/0", 1, ["x"]), ctx)
  end

  @tag obligation: "covenant.conditions.I6"
  test "value: a call that raises, throws or does not exist is suspect with what happened", %{
    ctx: ctx
  } do
    assert {:suspect, "Covenant.ExampleLimits.boom/0 raised ArgumentError: no limits today"} =
             Conditions.evaluate(value("Covenant.ExampleLimits.boom/0", 1), ctx)

    assert {:suspect, "Covenant.ExampleLimits.thrower/0 raised throw :nope"} =
             Conditions.evaluate(value("Covenant.ExampleLimits.thrower/0", 1), ctx)

    assert {:suspect, "Covenant.ExampleLimits.gone/0 raised UndefinedFunctionError: " <> _} =
             Conditions.evaluate(value("Covenant.ExampleLimits.gone/0", 1), ctx)
  end

  @tag obligation: "covenant.conditions.I7"
  test "value: a call into Elixir or OTP is refused as suspect, never made", %{ctx: ctx} do
    assert {:suspect, message} = Conditions.evaluate(value("Kernel.node/0", :nonode@nohost), ctx)
    assert message =~ "part of Elixir or OTP"

    assert {:suspect, halt} = Conditions.evaluate(value("System.halt/0", 0), ctx)
    assert halt =~ "System.halt/0"
    assert halt =~ "part of Elixir or OTP"
  end

  @tag obligation: "covenant.conditions.I7"
  test "a module counter in Elixir or OTP is refused, never called" do
    for {module, function} <- [{System, :schedulers_online}, {System, :halt}, {Kernel, :node}] do
      ceiling = %Ceiling{
        name: "x",
        ceiling: 100,
        counter: {:module, module, function},
        file: "system/scope.yml",
        line: 1
      }

      assert {:error, message} = Ceiling.count(ceiling, [])
      assert message =~ "#{inspect(module)}.#{function}/0"
      assert message =~ "part of Elixir or OTP"
    end
  end

  @tag obligation: "covenant.conditions.I8"
  test "file: a path that leaves the project root is suspect even when the file exists", %{
    ctx: ctx,
    tmp_dir: dir
  } do
    sibling = "outside-#{System.unique_integer([:positive])}.txt"
    File.write!(Path.join(Path.dirname(dir), sibling), "")
    on_exit(fn -> File.rm(Path.join(Path.dirname(dir), sibling)) end)
    up = Path.join("..", sibling)
    assert File.exists?(Path.join(dir, up))

    assert {:suspect, message} =
             Conditions.evaluate(premise(%{"kind" => "file", "path" => up}), ctx)

    assert message =~ "outside the project root"

    absolute = Path.expand("mix.exs")
    assert File.exists?(absolute)

    assert {:suspect, message} =
             Conditions.evaluate(premise(%{"kind" => "file", "path" => absolute}), ctx)

    assert message =~ "outside the project root"

    assert {:ok, _} =
             Conditions.evaluate(premise(%{"kind" => "file", "path" => "./present.txt"}), ctx)

    assert {:ok, _} = Conditions.evaluate(premise(%{"kind" => "file", "path" => "."}), ctx)
  end

  @tag obligation: "covenant.conditions.I9"
  test "value: names from a record never become atoms", %{ctx: ctx} do
    n = System.unique_integer([:positive])
    module = "Covenant.Atomless#{n}.Deeper"
    fun = "atomless_fun_#{n}"

    assert {:unchecked, "module not compiled in this VM: " <> reported} =
             Conditions.evaluate(value("#{module}.#{fun}/0", 1), ctx)

    assert reported == module

    assert {:suspect, message} =
             Conditions.evaluate(value("Covenant.ExampleLimits.#{fun}/0", 1), ctx)

    assert message =~ "Covenant.ExampleLimits.#{fun}/0 raised UndefinedFunctionError: "

    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> module) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(fun) end
  end

  @tag obligation: "covenant.conditions.I6"
  test "value: a module that is not compiled in this VM is unchecked with a reason, not suspect",
       %{ctx: ctx} do
    assert {:unchecked, "module not compiled in this VM: Covenant.NoSuchLimits.Deeper"} =
             Conditions.evaluate(value("Covenant.NoSuchLimits.Deeper.limits/0", 20, ["x"]), ctx)

    # a check that is also incomplete is incomplete first: nothing is silently unchecked
    assert {:suspect, "check `value` is incomplete: " <> _} =
             Conditions.evaluate(value("Covenant.NoSuchLimits.limits/1", 20), ctx)
  end

  @tag obligation: "covenant.conditions.I2"
  test "value: only Module.fun/0 with equals and a path of keys is a complete check", %{ctx: ctx} do
    for call <- [
          "Covenant.ExampleLimits.limits/1",
          "Covenant.ExampleLimits.limits/00",
          "Covenant.ExampleLimits.limits/",
          "Covenant.ExampleLimits.limits",
          "Covenant.ExampleLimits/0",
          "covenant.limits/0",
          "limits/0",
          "Covenant.ExampleLimits.Limits/0",
          "Covenant.ExampleLimits.limits/0 now",
          "now Covenant.ExampleLimits.limits/0",
          "Covenant.ExampleLimits.limits/0\n",
          "",
          123,
          nil
        ] do
      assert {:suspect, "check `value` is incomplete: " <> _} =
               Conditions.evaluate(value(call, 20, ["claim_batch"]), ctx),
             "call #{inspect(call)}"
    end

    for path <- ["claim_batch", 1, [1], [["claim_batch"]], [%{}], %{"a" => 1}] do
      assert {:suspect, "check `value` is incomplete: " <> _} =
               Conditions.evaluate(value(@limits, 20, path), ctx),
             "path #{inspect(path)}"
    end

    no_equals = %{"kind" => "value", "call" => @limits, "path" => ["claim_batch"]}

    assert {:suspect, "check `value` is incomplete: " <> _} =
             Conditions.evaluate(premise(no_equals), ctx)

    # the other kinds' fields never rescue a value check
    foreign = %{
      "kind" => "value",
      "name" => "DATABASE_URL",
      "path" => ["claim_batch"],
      "version" => "1"
    }

    assert {:suspect, "check `value` is incomplete: " <> _} =
             Conditions.evaluate(premise(foreign), ctx)
  end

  @tag obligation: "covenant.conditions.I3"
  test "reads a mix.lock into name => version, nil for non-hex deps", %{ctx: ctx} do
    path = Path.join(ctx.root, "mix.lock")

    File.write!(path, """
    %{
      "postgrex": {:hex, :postgrex, "0.20.1", "abc", [:mix], [], "hexpm", "def"},
      "mine": {:git, "https://example.com/mine.git", "deadbeef", []},
    }
    """)

    # Mix quotes every key; reading must not leak the compiler's "quotes not required" warning
    assert {%{"postgrex" => "0.20.1", "mine" => nil}, []} =
             Code.with_diagnostics(fn -> Conditions.read_lock(path) end)

    assert Conditions.read_lock(Path.join(ctx.root, "nope.lock")) == %{}

    for text <- ["%{", "42", "[postgrex: 1]"] do
      File.write!(path, text)
      assert Conditions.read_lock(path) == %{}, "lock text #{inspect(text)}"
    end

    # the version is the third element of a hex entry; one too short to carry it is nil
    File.write!(path, """
    %{
      "tiny": {:hex, :tiny, "1.0.0"},
      "short": {:hex, :short},
    }
    """)

    assert Conditions.read_lock(path) == %{"tiny" => "1.0.0", "short" => nil}
  end

  @tag obligation: "covenant.conditions.I5"
  test "context/1 reads the running system and the project's lock" do
    ctx = Conditions.context(root: ContractBuilder.fixture_project())
    assert ctx.elixir_version == System.version()
    assert Map.has_key?(ctx.lock, "yaml_elixir")
    assert Map.has_key?(ctx.env, "PATH")

    # the full version the release's OTP_VERSION file reports ("28.5"), not just the major ("28")
    release = :erlang.system_info(:otp_release) |> List.to_string()
    file = Path.join([to_string(:code.root_dir()), "releases", release, "OTP_VERSION"])
    assert {:ok, text} = File.read(file)
    assert ctx.otp_version == String.trim(text)
  end

  @tag obligation: "covenant.conditions.I4"
  test "the fixture Contract has no suspect records against the real system" do
    contract = Contract.load!(ContractBuilder.fixture_contracts())
    ctx = Conditions.context(root: ContractBuilder.fixture_project())
    assert Conditions.suspects(contract, ctx) == []
    assert length(Conditions.check_all(contract, ctx)) == 5
  end

  @tag obligation: "covenant.conditions.I4"
  test "suspects lists only records with a failing premise, with only the failing conditions", %{
    ctx: ctx
  } do
    contract = Contract.load!(ContractBuilder.fixture_contracts())
    ctx = %{ctx | root: ContractBuilder.fixture_project(), lock: %{}, env: %{"PATH" => "x"}}
    assert [{record, [{%Condition{text: text}, reason}]}] = Conditions.suspects(contract, ctx)
    assert record.id == "positive-steps"
    assert text =~ "yaml_elixir"
    assert reason == "dependency `yaml_elixir` is not in mix.lock"
  end
end
