defmodule Covenant.CoversCodePathContractTest do
  use Covenant.Case, component: "covenant.primitive", async: false

  alias Covenant.Covers

  @tag :tmp_dir
  @tag obligation: "covenant.primitive.I2"
  test "a covers module whose atom is new but whose beam is on the code path exists", %{
    tmp_dir: dir
  } do
    # the name is only ever a string here, so its atom does not exist in this VM
    name = "Covenant.CoversProbe#{System.unique_integer([:positive])}x"
    elixir = System.find_executable("elixir") || raise "elixir not on PATH"

    code = """
    [{mod, bin}] = Code.compile_string("defmodule #{name} do\\n def f(a), do: a\\nend")
    File.write!(Path.join(#{inspect(dir)}, Atom.to_string(mod) <> ".beam"), bin)
    """

    assert {_, 0} = System.cmd(elixir, ["-e", code])
    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    refute Covers.exists?({:module, name}, [])

    Code.prepend_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)

    assert Covers.exists?({:module, name}, [])
    assert Covers.exists?({:function, name, "f", 1}, [])
    refute Covers.exists?({:function, name, "f", 2}, [])

    refute Covers.exists?(
             {:module, "Covenant.NoSuchProbe#{System.unique_integer([:positive])}"},
             []
           )
  end
end
