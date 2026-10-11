defmodule Vm.ChmodContractTest do
  use Covenant.Case, component: "vm.chmod", async: false

  # leaves a read-only directory in its tmp_dir, which the next run of this test must clear
  @tag :tmp_dir
  @tag obligation: "vm.chmod.I1"
  test "doubles, and leaves a read-only directory behind", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "ro/inner"))
    File.write!(Path.join(tmp_dir, "ro/inner/f"), "x")
    File.chmod!(Path.join(tmp_dir, "ro/inner"), 0o500)
    File.chmod!(Path.join(tmp_dir, "ro"), 0o500)
    assert Vm.Chmod.double(2) == 4
  end
end
