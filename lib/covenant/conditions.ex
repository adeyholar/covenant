defmodule Covenant.Conditions do
  @moduledoc """
  Re-checks the machine-checkable `conditions` of decision records.

  A record's premises expire quietly: a dependency is swapped, an environment
  fact changes, a version moves on. `mix covenant.conditions` evaluates every
  condition that carries a `check` (see `Covenant.Contract.Condition`) and
  lists the records whose premises no longer hold, so they can be re-examined.
  """

  alias Covenant.Contract
  alias Covenant.Contract.{Condition, Record}

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

  @type outcome :: {:ok, String.t()} | {:suspect, String.t()} | :unchecked

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

  def evaluate(%Condition{check: %{"kind" => "file", "path" => path}}, ctx) do
    if ctx.root |> Path.join(path) |> File.exists?(),
      do: {:ok, "file `#{path}` exists"},
      else: {:suspect, "file `#{path}` does not exist"}
  end

  def evaluate(%Condition{check: %{"kind" => "otp", "version" => req}}, ctx),
    do: version_matches(ctx.otp_version, req, "OTP")

  def evaluate(%Condition{check: %{"kind" => "elixir", "version" => req}}, ctx),
    do: version_matches(ctx.elixir_version, req, "Elixir")

  def evaluate(%Condition{check: %{"kind" => kind} = check}, _ctx)
      when kind in ~w(env file otp elixir),
      do: {:suspect, "check `#{kind}` is incomplete: #{inspect(check)}"}

  def evaluate(%Condition{check: %{"kind" => kind}}, _ctx),
    do: {:suspect, "unknown check kind `#{kind}` (expected dep, env, file, otp or elixir)"}

  def evaluate(%Condition{check: other}, _ctx),
    do: {:suspect, "malformed check #{inspect(other)}"}

  defp version_matches(nil, req, what),
    do: {:suspect, "#{what} has no version to compare with `#{req}`"}

  defp version_matches(version, req, what) do
    normalized = normalize_version(version)

    case Version.parse_requirement(to_string(req)) do
      {:ok, requirement} ->
        if Version.match?(normalized, requirement),
          do: {:ok, "#{what} #{version} matches `#{req}`"},
          else: {:suspect, "#{what} is #{version}, which does not match `#{req}`"}

      :error ->
        {:suspect, "`#{req}` is not a valid version requirement"}
    end
  end

  # OTP reports "28" or "28.5"; Version needs three parts.
  defp normalize_version(version) do
    case String.split(to_string(version), ".") do
      [major] -> "#{major}.0.0"
      [major, minor] -> "#{major}.#{minor}.0"
      _ -> to_string(version)
    end
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
