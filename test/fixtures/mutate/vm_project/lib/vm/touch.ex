defmodule Vm.Touch do
  @moduledoc false

  # a mutant that negates the condition writes a file by a cwd-relative path
  def touch(flag \\ false) do
    if flag, do: File.write!("covenant_mutate_escaped.txt", "escaped")
    :ok
  end
end
