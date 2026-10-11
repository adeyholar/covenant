defmodule Covenant.Conditions do
  @moduledoc """
  Re-checks the machine-checkable `conditions` of decision records.

  A record's premises expire quietly: a dependency is swapped, an environment
  fact changes, a version moves on. `mix covenant.conditions` evaluates every
  condition that carries a `check` (see `Covenant.Contract.Condition`) and
  lists the records whose premises no longer hold, so they can be re-examined.
  """

  alias Covenant.Contract
  alias Covenant.Contract.{Ceiling, Condition, Record}
  alias Covenant.Target

  defmodule Context do
    @moduledoc "The facts conditions are checked against; built by `Covenant.Conditions.context/1`."

    @type t :: %__MODULE__{
            root: Path.t(),
            lock: %{String.t() => String.t() | nil},
            env: %{String.t() => String.t()},
            elixir_version: String.t(),
            otp_version: String.t()
          }

    defstruct root: ".", lock: %{}, env: %{}, elixir_version: "0.0.0", otp_version: "0.0.0"
  end

  @typedoc """
  `:unchecked` is a condition with no `check`; `{:unchecked, reason}` is a check that cannot be
  evaluated in this VM, which is never a failure.
  """
  @type outcome ::
          {:ok, String.t()} | {:suspect, String.t()} | :unchecked | {:unchecked, String.t()}

  @doc """
  Builds the context from the running system. Options:

  * `:root` — the project root holding `mix.lock` (default: current directory).
  """
  @spec context(keyword()) :: Context.t()
  def context(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    %Context{
      root: root,
      lock: read_lock(Path.join(root, "mix.lock")),
      env: System.get_env(),
      elixir_version: System.version(),
      otp_version: otp_version()
    }
  end

  @doc "Reads `mix.lock` into a map of dependency name to version (`nil` for non-hex deps)."
  @spec read_lock(Path.t()) :: %{String.t() => String.t() | nil}
  def read_lock(path) do
    with {:ok, text} <- File.read(path),
         {:ok, quoted} <-
           Code.string_to_quoted(text, warn_on_unnecessary_quotes: false, emit_warnings: false),
         {lock, _} when is_map(lock) <- Code.eval_quoted(quoted) do
      Map.new(lock, fn
        {app, tuple} when is_tuple(tuple) and tuple_size(tuple) >= 3 and elem(tuple, 0) == :hex ->
          {to_string(app), elem(tuple, 2)}

        {app, _other} ->
          {to_string(app), nil}
      end)
    else
      _ -> %{}
    end
  end

  @doc "The running OTP version, as reported by the release's `OTP_VERSION` file."
  @spec otp_version() :: String.t()
  def otp_version do
    release = :erlang.system_info(:otp_release) |> List.to_string()
    path = Path.join([:code.root_dir() |> List.to_string(), "releases", release, "OTP_VERSION"])

    case File.read(path) do
      {:ok, version} -> String.trim(version)
      _ -> release
    end
  end

  @doc "Evaluates one condition against the context."
  @spec evaluate(Condition.t(), Context.t()) :: outcome()
  def evaluate(%Condition{check: nil}, _ctx), do: :unchecked

  def evaluate(%Condition{check: %{"kind" => "dep"} = check}, ctx) do
    name = check["name"]

    case Map.fetch(ctx.lock, to_string(name)) do
      :error ->
        {:suspect, "dependency `#{name}` is not in mix.lock"}

      {:ok, version} ->
        case check["version"] do
          nil -> {:ok, "dependency `#{name}` is locked#{if version, do: " at #{version}"}"}
          req -> version_matches(version, req, "dependency `#{name}`")
        end
    end
  end

  def evaluate(%Condition{check: %{"kind" => "env", "name" => name}}, ctx) do
    if Map.has_key?(ctx.env, to_string(name)),
      do: {:ok, "env `#{name}` is set"},
      else: {:suspect, "env `#{name}` is not set"}
  end

  def evaluate(%Condition{check: %{"kind" => "file", "path" => path}}, ctx)
      when is_binary(path) do
    cond do
      not Target.within?(path, ctx.root) ->
        {:suspect, "file `#{path}` is outside the project root"}

      ctx.root |> Path.join(path) |> File.exists?() ->
        {:ok, "file `#{path}` exists"}

      true ->
        {:suspect, "file `#{path}` does not exist"}
    end
  end

  def evaluate(%Condition{check: %{"kind" => "otp", "version" => req}}, ctx),
    do: version_matches(ctx.otp_version, req, "OTP")

  def evaluate(%Condition{check: %{"kind" => "elixir", "version" => req}}, ctx),
    do: version_matches(ctx.elixir_version, req, "Elixir")

  def evaluate(%Condition{check: %{"kind" => "value"} = check}, _ctx), do: evaluate_value(check)

  def evaluate(%Condition{check: %{"kind" => kind} = check}, _ctx)
      when kind in ~w(env file otp elixir),
      do: incomplete(kind, check)

  def evaluate(%Condition{check: %{"kind" => kind}}, _ctx),
    do: {:suspect, "unknown check kind `#{kind}` (expected dep, env, file, otp, elixir or value)"}

  def evaluate(%Condition{check: other}, _ctx),
    do: {:suspect, "malformed check #{inspect(other)}"}

  defp incomplete(kind, check),
    do: {:suspect, "check `#{kind}` is incomplete: #{inspect(check)}"}

  # A `value` check calls `Module.fun/0` in this VM and compares what it returns (at `path`)
  # with what the record says. The module being absent is not a failure: it is not checked here.
  defp evaluate_value(%{"call" => call, "equals" => expected} = check) when is_binary(call) do
    path = Map.get(check, "path", [])

    with {:ok, module, fun} <- parse_call(call),
         true <- is_list(path) and Enum.all?(path, &(is_binary(&1) or is_atom(&1))) do
      cond do
        not (is_atom(module) and Code.ensure_loaded?(module)) ->
          {:unchecked, "module not compiled in this VM: #{Target.describe({:module, module})}"}

        Ceiling.system_module?(module) ->
          {:suspect,
           "#{call} is refused: #{inspect(module)} is part of Elixir or OTP and is not called"}

        true ->
          read_value(call, module, fun, path, expected)
      end
    else
      _ -> incomplete("value", check)
    end
  end

  defp evaluate_value(check), do: incomplete("value", check)

  defp parse_call(call) do
    case Regex.run(~r/\A([A-Z]\w*(?:\.[A-Z]\w*)*)\.([a-z_]\w*[?!]?)\/(\d+)\z/, call) do
      [_, module, fun, "0"] -> {:ok, existing_module(module), fun}
      _ -> :error
    end
  end

  # No new atom: the module's atom if it already exists, else its name.
  defp existing_module(name) do
    String.to_existing_atom("Elixir." <> String.replace_prefix(name, "Elixir.", ""))
  rescue
    ArgumentError -> name
  end

  defp read_value(call, module, fun, path, expected) do
    where = if path == [], do: call, else: "#{call} [#{Enum.map_join(path, ", ", &to_string/1)}]"

    with {:ok, result} <- invoke(module, fun),
         {:ok, actual} <- dig(result, path) do
      if normalize(actual) == normalize(expected),
        do: {:ok, "#{where} is #{inspect(actual)}"},
        else: {:suspect, "#{where} is #{inspect(actual)}, the record says #{inspect(expected)}"}
    else
      {:raised, what} -> {:suspect, "#{call} raised #{what}"}
      {:missing, key} -> {:suspect, "#{where} has no key `#{key}`"}
    end
  end

  # The function atom is taken from the module's own exports by name, never made from the string.
  defp invoke(module, fun) do
    case Enum.find(module.module_info(:exports), &(elem(&1, 1) == 0 and name_is?(&1, fun))) do
      {name, 0} ->
        {:ok, apply(module, name, [])}

      nil ->
        {:raised, "UndefinedFunctionError: function #{inspect(module)}.#{fun}/0 is undefined"}
    end
  rescue
    exception -> {:raised, "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"}
  catch
    kind, reason -> {:raised, "#{kind} #{inspect(reason)}"}
  end

  defp name_is?({name, _arity}, fun), do: Atom.to_string(name) == fun

  defp dig(value, []), do: {:ok, value}

  defp dig(value, [key | rest]) when is_map(value) do
    case fetch_key(value, key) do
      {:ok, inner} -> dig(inner, rest)
      :error -> {:missing, key}
    end
  end

  defp dig(_value, [key | _rest]), do: {:missing, key}

  # YAML keys are strings and code keys are usually atoms: the atom form first, then the string.
  defp fetch_key(map, key) do
    Enum.find_value(key_forms(key), :error, fn form ->
      case Map.fetch(map, form) do
        {:ok, _} = found -> found
        :error -> nil
      end
    end)
  end

  defp key_forms(key) when is_atom(key), do: [key, Atom.to_string(key)]

  defp key_forms(key) do
    [String.to_existing_atom(key), key]
  rescue
    ArgumentError -> [key]
  end

  # A record's YAML says `chat` where the code returns `:chat`; numbers compare by value.
  defp normalize(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value

  defp version_matches(nil, req, what),
    do: {:suspect, "#{what} has no version to compare with `#{req}`"}

  defp version_matches(version, req, what) do
    with {:version, {:ok, parsed}} <-
           {:version, version |> normalize_version() |> Version.parse()},
         {:req, {:ok, requirement}} <-
           {:req, req |> to_string() |> pad_requirement() |> Version.parse_requirement()} do
      if Version.match?(parsed, requirement),
        do: {:ok, "#{what} #{version} matches `#{req}`"},
        else: {:suspect, "#{what} is #{version}, which does not match `#{req}`"}
    else
      {:version, :error} ->
        {:suspect, "#{what} version `#{version}` cannot be compared with `#{req}`"}

      {:req, :error} ->
        {:suspect, "`#{req}` is not a valid version requirement"}
    end
  end

  # OTP reports "28", "28.5" or "27.3.4.1"; Version needs exactly three numbers.
  defp normalize_version(version) do
    version = to_string(version)

    if version =~ ~r/\A\d+(\.\d+)*\z/ do
      parts = version |> String.split(".") |> Enum.take(3)
      Enum.join(parts ++ List.duplicate("0", 3 - length(parts)), ".")
    else
      version
    end
  end

  # Records write `>= 28.0` where Version needs `>= 28.0.0`. `~>` is left as written: `~> 28.0`
  # means below 29, which `~> 28.0.0` would not.
  defp pad_requirement(req) do
    Regex.replace(
      ~r/(?<![~<>=])((?:>=|<=|==|>|<)\s*)(\d+)(?:\.(\d+))?(?![\d.\w-])/,
      req,
      fn _match, operator, major, minor ->
        "#{operator}#{major}.#{if minor == "", do: "0", else: minor}.0"
      end
    )
  end

  @doc "Evaluates every condition of a record."
  @spec check_record(Record.t(), Context.t()) :: [{Condition.t(), outcome()}]
  def check_record(%Record{conditions: conditions}, ctx),
    do: Enum.map(conditions, &{&1, evaluate(&1, ctx)})

  @doc """
  Evaluates every record of the Contract. Returns `{record, outcomes}` pairs
  in file order; `suspects/2` keeps only the records with a failing premise.
  """
  @spec check_all(Contract.t(), Context.t()) :: [{Record.t(), [{Condition.t(), outcome()}]}]
  def check_all(%Contract{records: records}, ctx) do
    records
    |> Map.values()
    |> Enum.sort_by(&{&1.file, &1.line})
    |> Enum.map(&{&1, check_record(&1, ctx)})
  end

  @doc "Records with at least one suspect condition, with only the suspect outcomes."
  @spec suspects(Contract.t(), Context.t()) :: [{Record.t(), [{Condition.t(), String.t()}]}]
  def suspects(%Contract{} = contract, ctx) do
    contract
    |> check_all(ctx)
    |> Enum.map(fn {record, outcomes} ->
      {record, for({condition, {:suspect, reason}} <- outcomes, do: {condition, reason})}
    end)
    |> Enum.reject(fn {_, failures} -> failures == [] end)
  end
end
