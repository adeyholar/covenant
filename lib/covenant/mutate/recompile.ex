defmodule Covenant.Mutate.Recompile do
  @moduledoc false

  alias Covenant.Mutate.Mutator

  @type t :: %{files: [map()], originals: [{module(), binary(), charlist()}]}

  @doc false
  @spec prepare([Path.t()], Path.t(), [Path.t()]) :: {:ok, t()} | {:error, String.t()}
  def prepare(patterns, root, targets) do
    with {:ok, paths} <- expand(patterns, root, targets),
         {:ok, files} <- parse(paths),
         {:ok, compiled} <- compile(%{files: files}) do
      # Caller compilation establishes the baseline. A disk BEAM can be older
      # or use different compile-time settings, so retain these exact binaries.
      originals = Enum.map(compiled, fn {module, binary} -> {module, binary, ~c"nofile"} end)
      {:ok, %{files: files, originals: originals}}
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
    relative = Path.relative_to(path, root)

    String.starts_with?(path, root <> "/") and
      Path.extname(path) in [".ex", ".exs"] and File.regular?(path) and
      :filelib.safe_relative_path(String.to_charlist(relative), String.to_charlist(root)) !=
        :unsafe and
      path not in targets
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
  @spec loaded_modules() :: MapSet.t(module())
  def loaded_modules, do: MapSet.new(:code.all_loaded(), &elem(&1, 0))

  @doc false
  @spec remove_generated(MapSet.t(module())) :: :ok
  def remove_generated(loaded) do
    # Elixir loads compiled modules with an empty code filename, including
    # Module.create/3 with virtual sources. Disk modules loaded on demand have
    # a BEAM filename and must remain loaded. The snapshot also protects all
    # modules that existed before this mutant, including in-memory fixtures.
    for {module, []} <- :code.all_loaded(), not MapSet.member?(loaded, module) do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end
end
