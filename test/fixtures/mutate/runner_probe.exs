[component, module, file, test_file | _rest] = System.argv()
Mix.shell(Mix.Shell.IO)

plan = %{
  component: component,
  modules: [{Module.concat([module]), Path.expand(file)}],
  test_files: [test_file],
  root: File.cwd!(),
  seed: 0,
  timeout: nil,
  slice: {1, 1},
  on_progress: fn m -> IO.puts("  #{m.id} #{m.verdict} #{Covenant.Mutate.Mutant.mutation(m)}") end,
  on_timeout: fn result, mutant ->
    IO.puts("ON_TIMEOUT #{mutant.id} #{length(result.mutants)}")
    System.halt(Covenant.Mutate.Runner.timeout_exit())
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
