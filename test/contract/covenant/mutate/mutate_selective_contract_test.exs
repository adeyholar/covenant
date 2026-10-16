defmodule Covenant.MutateSelectiveContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false
  alias Covenant.Mutate.{Mutator, Recompile}
  @moduletag :tmp_dir
  @moduletag obligation: "covenant.mutate.I32"

  test "runtime calls inside macros and verification callbacks retain transitive callers; unrelated files stay compiled",
       %{tmp_dir: root} do
    base = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    target = Module.concat(base, Runtime)
    point = Module.concat(base, Point)
    cached = Module.concat(base, Cached)
    derived = Module.concat(base, Derived)
    unrelated = Module.concat(base, Unrelated)
    verifier = Module.concat(base, Verifier)
    builder = Module.concat(base, Builder)

    sources = [
      {"cached.ex", "defmodule #{cached} do require #{builder}; #{builder}.embed() end"},
      {"derived.ex",
       "defmodule #{derived} do @value #{cached}.value(); def value, do: @value end"},
      {"unrelated.ex",
       "defmodule #{unrelated} do :persistent_term.put({__MODULE__, :count}, :persistent_term.get({__MODULE__, :count}, 0) + 1); def value, do: :unchanged end"},
      {"verified.ex",
       "defmodule #{base}.Verified do @after_verify {#{verifier}, :check}; def value, do: :ok end"},
      {"struct.ex", "defmodule #{base}.StructCaller do def value, do: %#{point}{} end"},
      {"generated.ex",
       "defmodule #{base}.Generated do Code.compile_string(\"defmodule #{base}.Nested do def value, do: 1 end\") end"}
    ]

    target_source =
      "defmodule #{target} do def value, do: 42 end; defmodule #{point} do defstruct value: 42 end"

    target_ast = compile(target_source, Path.join(root, "target.ex"))

    compile(
      "defmodule #{base}.Indirect do def value, do: #{target}.value() end",
      Path.join(root, "indirect.ex")
    )

    macro_ast =
      compile(
        "defmodule #{builder} do defmacro embed do value = #{base}.Indirect.value(); quote do def value, do: unquote(value) end end end",
        Path.join(root, "builder.ex")
      )

    compile(
      "defmodule #{verifier} do def check(_module), do: #{target}.value() end",
      Path.join(root, "verifier.ex")
    )

    for {name, source} <- sources, do: compile(source, Path.join(root, name))

    paths =
      Enum.map(sources, fn {name, source} ->
        path = Path.join(root, name)
        File.write!(path, source)
        path
      end)

    on_exit(fn ->
      :persistent_term.erase({unrelated, :count})

      for {module, _} <- :code.all_loaded(),
          String.starts_with?(Atom.to_string(module), Atom.to_string(base) <> ".") do
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end
    end)

    assert {:ok, callers} =
             Recompile.prepare(paths, root, [], selective: true, modules: [target, point])

    assert MapSet.member?(
             Enum.find(callers.files, &String.ends_with?(&1.file, "cached.ex")).dependencies,
             target
           )

    assert MapSet.member?(
             Enum.find(callers.files, &String.ends_with?(&1.file, "verified.ex")).dependencies,
             target
           )

    assert Enum.find(callers.files, &String.ends_with?(&1.file, "generated.ex")).dependencies ==
             :all

    selected = Recompile.affected(callers, [target], target_ast)

    assert Enum.map(selected.files, &Path.basename(&1.file)) == [
             "cached.ex",
             "derived.ex",
             "verified.ex",
             "generated.ex"
           ]

    assert Recompile.affected(callers, [target], macro_ast) == callers
    struct_callers = Recompile.affected(callers, [point], target_ast)
    assert "struct.ex" in Enum.map(struct_callers.files, &Path.basename(&1.file))
    count = :persistent_term.get({unrelated, :count})
    compile("defmodule #{target} do def value, do: 41 end", Path.join(root, "target.ex"))
    assert {:ok, _} = Recompile.compile(selected)
    assert apply(cached, :value, []) == 41
    assert apply(derived, :value, []) == 41
    assert :persistent_term.get({unrelated, :count}) == count
    assert {:ok, _} = Recompile.prepare(paths, root, [])

    refute Code.get_compiler_option(:tracers)
           |> Enum.member?(Covenant.Mutate.Recompile.Dependencies)
  end

  defp compile(source, path) do
    {:ok, ast} = Mutator.parse(source, path)
    {:ok, _} = Mutator.compile(ast, path)
    ast
  end
end
