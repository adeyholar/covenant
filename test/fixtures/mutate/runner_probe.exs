[component, module, file, test_file | rest] = System.argv()
timeout = with [ms | _] <- rest, do: String.to_integer(ms), else: (_ -> nil)
Mix.shell(Mix.Shell.IO)

plan = %{
  component: component,
  modules: [{Module.concat([module]), Path.expand(file)}],
  test_files: [test_file],
  root: File.cwd!(),
  seed: 0,
  timeout: timeout,
  slice: {1, 1},
  on_progress: fn m -> IO.puts("  #{m.id} #{m.verdict} #{Covenant.Mutate.Mutant.mutation(m)}") end,
  # the callback runs inside the worker's copy and does not halt: the runner does,
  # after it has removed the copy; the pause lets a mutant's stray processes write
  on_timeout: fn result, mutant ->
    IO.puts("ON_TIMEOUT #{mutant.id} #{length(result.mutants)}")
    IO.puts("CWD_IN_CALLBACK #{File.cwd!()}")
  end,
  halt: fn status ->
    Process.sleep(1_000)
    IO.puts("CWD_AT_HALT #{inspect(File.cwd())}")
    System.halt(status)
  end
}

IO.inspect(
  Covenant.Mutate.Runner.run(plan)
  |> then(fn
    {:ok, r} -> {:ok, length(r.mutants)}
    e -> e
  end),
  label: "RESULT"
)
