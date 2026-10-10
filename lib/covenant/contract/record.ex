defmodule Covenant.Contract.Condition do
  @moduledoc """
  A premise of a decision record.

  `text` is the human statement; `check`, when present, is the machine-checkable
  form evaluated by `mix covenant.conditions`. Covenant understands these
  check kinds (keys as written in YAML):

  | kind     | fields                     | holds when                                        |
  |----------|----------------------------|---------------------------------------------------|
  | `dep`    | `name`, optional `version` | `name` is in `mix.lock`, matching `version`       |
  | `env`    | `name`                     | the environment variable is set                   |
  | `file`   | `path`                     | the path exists (relative to the project root)    |
  | `otp`    | `version`                  | the running OTP release matches the requirement   |
  | `elixir` | `version`                  | the running Elixir version matches the requirement|
  """

  @type t :: %__MODULE__{text: String.t(), check: map() | nil}

  @enforce_keys [:text]
  defstruct [:text, :check]
end

defmodule Covenant.Contract.Record do
  @moduledoc """
  A decision record from a `*.decisions.yml` file.

  Records carry the reasons behind values that would look arbitrary to a
  competent stranger. They are never deleted, only superseded, which is why
  `superseded_by` is checked for dangling references.
  """

  alias Covenant.Contract.Condition

  @type alternative :: %{option: String.t(), rejected: String.t() | nil}

  @type t :: %__MODULE__{
          id: String.t(),
          component_id: String.t(),
          date: String.t(),
          decision: String.t(),
          driver: String.t(),
          approved_by: String.t() | nil,
          evidence: String.t() | nil,
          expires: String.t() | nil,
          kind: String.t() | nil,
          notes: String.t() | nil,
          superseded_by: String.t() | nil,
          invariant: [String.t()],
          alternatives: [alternative()],
          conditions: [Condition.t()],
          depends_on: [String.t()],
          source: [String.t()],
          file: String.t(),
          line: pos_integer()
        }

  @enforce_keys [:id, :component_id, :date, :decision, :driver, :file, :line]
  defstruct [
    :id,
    :component_id,
    :date,
    :decision,
    :driver,
    :approved_by,
    :evidence,
    :expires,
    :kind,
    :notes,
    :superseded_by,
    :file,
    :line,
    invariant: [],
    alternatives: [],
    conditions: [],
    depends_on: [],
    source: []
  ]

  @doc "Validates the kebab-case id shape."
  @spec valid_id?(String.t()) :: boolean()
  def valid_id?(id), do: Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, id)

  @doc "The record kinds the convention names."
  @spec kinds() :: [String.t()]
  def kinds, do: ["fact", "cross-system", "known-gap"]

  @doc "True when the record has been superseded by another."
  @spec superseded?(t()) :: boolean()
  def superseded?(%__MODULE__{superseded_by: nil}), do: false
  def superseded?(%__MODULE__{}), do: true
end
