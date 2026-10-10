defmodule Covenant.ConditionsContractTest do
  use Covenant.Case, component: "covenant.conditions", async: true

  alias Covenant.{Conditions, Contract}
  alias Covenant.Conditions.Context
  alias Covenant.Contract.Condition
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

  @tag obligation: "covenant.conditions.I2"
  test "unknown or incomplete checks are suspect, never silently ok", %{ctx: ctx} do
    assert {:suspect, "unknown check kind `weather` (expected dep, env, file, otp or elixir)"} =
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
          {"elixir", "version"}
        ] do
      check = foreign |> Map.delete(own) |> Map.put("kind", kind)

      assert {:suspect, reason} = Conditions.evaluate(premise(check), ctx)
      assert String.starts_with?(reason, "check `#{kind}` is incomplete: "), reason
    end
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
