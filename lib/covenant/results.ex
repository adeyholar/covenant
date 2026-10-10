defmodule Covenant.Results do
  @moduledoc """
  The outcome of a contract test run: one entry per obligation-tagged test.

  `Covenant.Formatter` writes one results file per app under
  `Covenant.results_dir/0`; `read_dir/1` merges them back so an umbrella's
  apps each contribute their own tests without overwriting each other.
  """

  defmodule Test do
    @moduledoc "One obligation-tagged test and how it ended."

    @type state :: :passed | :failed | :skipped | :excluded | :invalid

    @type t :: %__MODULE__{
            module: String.t(),
            name: String.t(),
            file: String.t() | nil,
            line: pos_integer() | nil,
            component: String.t() | nil,
            obligations: [String.t()],
            state: state()
          }

    @enforce_keys [:module, :name, :obligations, :state]
    defstruct [:module, :name, :file, :line, :component, obligations: [], state: :passed]
  end

  @type t :: %__MODULE__{apps: [String.t()], tests: [Test.t()]}

  defstruct apps: [], tests: []

  @states ~w(passed failed skipped excluded invalid)

  @doc "Converts a finished `ExUnit.Test` into a results entry, or `nil` when it carries no obligation tag."
  @spec from_ex_unit(ExUnit.Test.t()) :: Test.t() | nil
  def from_ex_unit(%ExUnit.Test{tags: tags} = test) do
    case tags[:obligation] do
      nil ->
        nil

      obligations ->
        %Test{
          module: inspect(test.module),
          name: Atom.to_string(test.name),
          file: tags[:file] && Path.relative_to_cwd(tags[:file]),
          line: tags[:line],
          component: tags[:covenant_component],
          obligations: obligations |> List.wrap() |> Enum.map(&to_string/1),
          state: state(test.state)
        }
    end
  end

  defp state(nil), do: :passed
  defp state({:failed, _}), do: :failed
  defp state({:skipped, _}), do: :skipped
  defp state({:excluded, _}), do: :excluded
  defp state({:invalid, _}), do: :invalid

  @doc "Encodes the tests of `app` as a JSON document."
  @spec encode(String.t(), [Test.t()]) :: iodata()
  def encode(app, tests) do
    Covenant.JSON.pretty(%{
      "covenant" => Covenant.version(),
      "app" => app,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tests" =>
        tests
        |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.name})
        |> Enum.map(fn test ->
          %{
            "module" => test.module,
            "name" => test.name,
            "file" => test.file,
            "line" => test.line,
            "component" => test.component,
            "obligations" => test.obligations,
            "state" => Atom.to_string(test.state)
          }
        end)
    })
  end

  @doc "Writes the results of `app` to `dir/<app>.json`."
  @spec write(Path.t(), String.t(), [Test.t()]) :: Path.t()
  def write(dir, app, tests) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{app}.json")
    File.write!(path, [encode(app, tests), "\n"])
    path
  end

  @doc "Reads every `*.json` results file in `dir`."
  @spec read_dir(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read_dir(dir) do
    files = dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

    if files == [] do
      {:error,
       "no contract test results in #{dir}; run the contract suite with Covenant.Formatter first"}
    else
      Enum.reduce_while(files, {:ok, %__MODULE__{}}, fn file, {:ok, acc} ->
        case read_file(file) do
          {:ok, app, tests} ->
            {:cont, {:ok, %{acc | apps: acc.apps ++ [app], tests: acc.tests ++ tests}}}

          {:error, reason} ->
            {:halt, {:error, "#{file}: #{reason}"}}
        end
      end)
    end
  end

  @doc "Decodes one results file."
  @spec read_file(Path.t()) :: {:ok, String.t(), [Test.t()]} | {:error, String.t()}
  def read_file(file) do
    with {:ok, text} <- File.read(file),
         {:ok, %{"app" => app, "tests" => tests}} when is_list(tests) <- JSON.decode(text) do
      {:ok, app, Enum.map(tests, &decode_test/1)}
    else
      {:ok, _} -> {:error, "not a Covenant results file"}
      {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason) |> to_string()}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  defp decode_test(map) do
    state = map["state"]

    %Test{
      module: map["module"],
      name: map["name"],
      file: map["file"],
      line: map["line"],
      component: map["component"],
      obligations: List.wrap(map["obligations"]),
      state: if(state in @states, do: String.to_existing_atom(state), else: :invalid)
    }
  end

  @doc "Groups tests by obligation id."
  @spec by_obligation(t() | [Test.t()]) :: %{String.t() => [Test.t()]}
  def by_obligation(%__MODULE__{tests: tests}), do: by_obligation(tests)

  def by_obligation(tests) when is_list(tests) do
    Enum.reduce(tests, %{}, fn test, acc ->
      Enum.reduce(test.obligations, acc, fn id, acc ->
        Map.update(acc, id, [test], &(&1 ++ [test]))
      end)
    end)
  end
end
