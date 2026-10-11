defmodule Vm.Compile do
  @moduledoc false

  # a mutant that turns the condition false (`true` becomes `false`): compiling the module then waits for a message that never comes
  @x if true, do: :ok, else: receive(do: (:never -> :ok))

  def x, do: @x
end
