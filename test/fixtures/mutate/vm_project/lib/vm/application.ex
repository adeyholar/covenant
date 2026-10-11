defmodule Vm.Application do
  @moduledoc false
  use Application

  # With VM_FUSE set the application starts only once per VM, as one whose start
  # cannot be repeated (a port or a file it holds, say): once a mutant has
  # stopped it, it stays down.
  def start(_type, _args) do
    if System.get_env("VM_FUSE") && :persistent_term.get({Vm, :started}, false) do
      {:error, :already_started_once}
    else
      :persistent_term.put({Vm, :started}, true)
      children = [%{id: Vm.Echo, start: {Vm.Application, :start_echo, []}}]
      Supervisor.start_link(children, strategy: :one_for_one, name: Vm.Sup)
    end
  end

  def start_echo do
    pid = spawn_link(Vm.Echo, :loop, [0])
    Process.register(pid, Vm.Echo)
    {:ok, pid}
  end
end
