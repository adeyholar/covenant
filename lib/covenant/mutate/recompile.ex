defmodule Covenant.Mutate.Recompile do
  @moduledoc false

  alias Covenant.Mutate.Mutator
  alias Covenant.Mutate.Recompile.Dependencies

  @type t :: %{files: [map()], originals: [{module(), binary(), charlist()}]}

  @doc false
  @spec prepare([Path.t()], Path.t(), [Path.t()]) :: {:ok, t()} | {:error, String.t()}
  def prepare(patterns, root, targets, options \\ []) do
    with {:ok, paths} <- expand(patterns, root, targets),
         {:ok, files} <- parse(paths),
         {:ok, files, compiled} <- prepare_dependencies(files, options) do
      # Caller compilation establishes the baseline. A disk BEAM can be older
      # or use different compile-time settings, so retain these exact binaries.
      originals = Enum.map(compiled, fn {module, binary} -> {module, binary, ~c"nofile"} end)

      {:ok,
       %{files: files, originals: originals, selective: Keyword.get(options, :selective, false)}}
    end
  end

  defp prepare_dependencies(files, options) do
    watched = Keyword.get(options, :modules, [])

    Enum.reduce_while(files, {:ok, [], []}, fn file, {:ok, prepared, compiled} ->
      result =
        if Keyword.get(options, :selective, false) do
          Dependencies.measure(
            fn -> Mutator.compile(file.ast, file.file) end,
            watched ++ Enum.map(compiled, &elem(&1, 0))
          )
        else
          {Mutator.compile(file.ast, file.file), :all}
        end

      case result do
        {{:ok, modules}, dependencies} ->
          file =
            Map.merge(file, %{
              dependencies: dependencies,
              modules: Enum.map(modules, &elem(&1, 0))
            })

          {:cont, {:ok, prepared ++ [file], compiled ++ modules}}

        {{:error, reason}, _} ->
          {:halt, {:error, "caller #{file.file} does not compile: #{reason}"}}
      end
    end)
  end

  @doc false
  def affected(%{selective: true} = callers, modules, ast) do
    # A macro file can change generated module names and declarations. Keep
    # the complete path for it, even for an ordinary function in that file.
    {_, macro?} =
      Macro.prewalk(ast, false, fn
        {kind, _, _} = node, _ when kind in [:defmacro, :defmacrop, :defguard, :defguardp] ->
          {node, true}

        node, found ->
          {node, found}
      end)

    if macro?, do: callers, else: select(callers, MapSet.new(modules))
  end

  def affected(callers, _modules, _ast), do: callers

  defp select(callers, changed) do
    affected =
      Enum.filter(callers.files, fn file ->
        file.dependencies == :all or not MapSet.disjoint?(file.dependencies, changed)
      end)

    expanded = Enum.reduce(affected, changed, &MapSet.union(MapSet.new(&1.modules), &2))

    if expanded == changed do
      modules = MapSet.new(Enum.flat_map(affected, & &1.modules))

      %{
        callers
        | files: affected,
          originals: Enum.filter(callers.originals, &MapSet.member?(modules, elem(&1, 0)))
      }
    else
      select(callers, expanded)
    end
  end

  defp expand(patterns, root, targets) do
    root = Path.expand(root)

    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, paths} ->
      matches = pattern |> Path.expand(root) |> Path.wildcard() |> Enum.sort()

      case Enum.find(matches, &(not allowed?(&1, root, targets))) do
        nil when matches != [] ->
          {:cont, {:ok, paths ++ matches}}

        nil ->
          {:halt, {:error, "recompile source not found: #{pattern}"}}

        path ->
          {:halt,
           {:error,
            "recompile source must be a project source outside the mutation targets: #{path}"}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, paths |> Enum.reverse() |> Enum.uniq() |> Enum.reverse()}
      error -> error
    end
  end

  defp allowed?(path, root, targets) do
    resolved = source_path(path, root)

    String.starts_with?(path, root <> "/") and
      Path.extname(path) in [".ex", ".exs"] and File.regular?(path) and
      resolved != :unsafe and
      Enum.all?(targets, &(source_path(&1, root) != resolved))
  end

  defp source_path(path, root) do
    path
    |> Path.relative_to(root)
    |> String.to_charlist()
    |> :filelib.safe_relative_path(String.to_charlist(root))
  end

  defp parse(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn file, {:ok, files} ->
      with {:ok, source} <- File.read(file),
           {:ok, ast} <- Mutator.parse(source, file) do
        {:cont, {:ok, files ++ [%{file: file, ast: ast}]}}
      else
        {:error, reason} ->
          {:halt, {:error, "cannot prepare recompile source #{file}: #{inspect(reason)}"}}
      end
    end)
  end

  @doc false
  @spec compile(map()) :: {:ok, [{module(), binary()}]} | {:error, String.t()}
  def compile(%{files: files}) do
    Enum.reduce_while(files, {:ok, []}, fn %{file: file, ast: ast}, {:ok, compiled} ->
      case Mutator.compile(ast, file) do
        {:ok, modules} -> {:cont, {:ok, compiled ++ modules}}
        {:error, reason} -> {:halt, {:error, "caller #{file} does not compile: #{reason}"}}
      end
    end)
  end

  @doc false
  @spec with_cleanup((-> result)) :: result when result: var
  def with_cleanup(fun) do
    loaded = loaded_modules()
    tracer = spawn_link(fn -> collect(MapSet.new()) end)
    session = :trace.session_create(__MODULE__, tracer, [])
    # Only the module name is sent, never the potentially large BEAM binary.
    match = [{[:"$1", [], :_], [], [{:message, :"$1"}]}]
    :trace.function(session, {:code, :load_binary, 3}, match, [:local])
    :trace.process(session, :all, true, [:call, :arity])

    try do
      fun.()
    after
      :trace.process(session, :all, false, [:call])
      ref = :trace.delivered(session, :all)

      receive do
        {:trace_delivered, :all, ^ref} -> :ok
      end

      send(tracer, {:modules, self(), ref})

      compiled =
        receive do
          {^ref, modules} -> modules
        end

      :trace.session_destroy(session)
      send(tracer, :stop)
      remove_generated(loaded, compiled)
    end
  end

  # Code.load_binary/3 observes Module.create/3 as well as compiler workers.
  # A deleted helper is absent from all_loaded/0 while old code can remain.
  defp collect(modules) do
    receive do
      {:trace, _pid, :call, {:code, :load_binary, 3}, module} ->
        collect(MapSet.put(modules, module))

      {:modules, caller, ref} ->
        send(caller, {ref, MapSet.to_list(modules)})
        collect(modules)

      :stop ->
        :ok

      _ ->
        collect(modules)
    end
  end

  @doc false
  @spec loaded_modules() :: MapSet.t(module())
  def loaded_modules, do: MapSet.new(:code.all_loaded(), &elem(&1, 0))

  @doc false
  @spec remove_generated(MapSet.t(module())) :: :ok
  def remove_generated(loaded, compiled \\ []) do
    # Elixir loads compiled modules with an empty code filename, including
    # Module.create/3 with virtual sources. Disk modules loaded on demand have
    # a BEAM filename and must remain loaded. The snapshot also protects all
    # modules that existed before this mutant, including in-memory fixtures.
    memory = for {module, []} <- :code.all_loaded(), do: module

    for module <- Enum.uniq(memory ++ compiled), not MapSet.member?(loaded, module) do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end
end

defmodule Covenant.Mutate.Recompile.Dependencies do
  @moduledoc false
  @key {__MODULE__, :collector}

  # Runtime traces see ordinary functions executed by macros, including
  # transitive private calls. Compiler events retain direct macro, struct,
  # and module-body references to other callers. Both are needed.
  @doc false
  def measure(fun, modules) do
    if __MODULE__ in modules do
      {fun.(), :all}
    else
      measured(fun, modules)
    end
  end

  defp measured(fun, modules) do
    collector = spawn_link(fn -> collect(MapSet.new(), false, 0) end)
    session = :trace.session_create(__MODULE__, collector, [])
    previous = Code.get_compiler_option(:tracers)
    :persistent_term.put(@key, collector)
    Code.put_compiler_option(:tracers, [__MODULE__ | previous])

    for module <- Enum.uniq(modules),
        do: :trace.function(session, {module, :_, :_}, true, [:local])

    for {module, name, arity} <- [{:erlang, :function_exported, 3}, {:code, :is_loaded, 1}] do
      head = [:"$1" | List.duplicate(:_, arity - 1)]
      :trace.function(session, {module, name, arity}, [{head, [], [{:message, :"$1"}]}], [:local])
    end

    for {name, arity} <- [
          compile_quoted: 2,
          compile_string: 2,
          compile_file: 2,
          eval_quoted: 3,
          eval_string: 3,
          require_file: 2
        ] do
      :trace.function(session, {Code, name, arity}, true, [:local])
    end

    :trace.function(session, {Module, :create, 3}, true, [:local])
    :trace.process(session, :all, true, [:call, :arity])
    :trace.process(session, collector, false, [:call])

    try do
      owner = self()
      {pid, ref} = spawn_monitor(fn -> send(owner, {self(), :compiled, fun.()}) end)

      result =
        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} ->
            receive do
              {^pid, :compiled, result} -> result
            end

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:error, "compiler exited: #{inspect(reason)}"}
        end

      :trace.process(session, :all, false, [:call])
      barrier = :trace.delivered(session, :all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      end

      send(collector, {:result, self(), barrier})

      dependencies =
        receive do
          {^barrier, dependencies} -> dependencies
        end

      {result, dependencies}
    after
      Code.put_compiler_option(:tracers, previous)
      :persistent_term.erase(@key)
      :trace.session_destroy(session)
      send(collector, :stop)
    end
  end

  @doc false
  def trace(event, env) do
    module =
      case event do
        {kind, _, module, _, _} when kind in [:remote_macro, :imported_macro] ->
          module

        {kind, _, module, _, _}
        when kind in [:remote_function, :imported_function] and is_nil(env.function) ->
          module

        {:struct_expansion, _, module, _} ->
          module

        _ ->
          nil
      end

    collector = :persistent_term.get(@key, nil)

    if module && collector do
      ref = make_ref()
      send(collector, {:dependency, module, self(), ref})

      receive do
        ^ref -> :ok
      end
    end

    :ok
  end

  defp collect(modules, uncertain, compiles) do
    receive do
      {:dependency, module, caller, ref} ->
        send(caller, ref)
        collect(MapSet.put(modules, module), uncertain, compiles)

      {:trace, _, :call, {Code, :compile_quoted, 2}} ->
        collect(modules, uncertain or compiles > 0, compiles + 1)

      {:trace, _, :call, {module, _, _}} when module in [Code, Module] ->
        collect(modules, true, compiles)

      {:trace, _, :call, {_, _, _}, module} when is_atom(module) ->
        collect(
          MapSet.put(modules, module),
          uncertain or :code.is_loaded(module) == false,
          compiles
        )

      {:trace, _, :call, {module, _, _}} ->
        collect(MapSet.put(modules, module), uncertain, compiles)

      {:result, caller, ref} ->
        send(caller, {ref, if(uncertain, do: :all, else: modules)})
        collect(modules, uncertain, compiles)

      :stop ->
        :ok

      _ ->
        collect(modules, uncertain, compiles)
    end
  end
end
