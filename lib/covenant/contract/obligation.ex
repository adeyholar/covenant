defmodule Covenant.Contract.Obligation do
  @moduledoc """
  One obligation block from an intent or obligations file.

  Obligations are the machine-readable promises of the Contract:

  ```markdown
  ### example.counter.I1 — A counter never goes below zero
  - **scope:** `Example.Counter.decrement/2`
  - **must:** clamp at zero instead of going negative
  - **why:** v1 billed negative balances (incident #12)
  - **kind:** functional
  - **record:** clamp-at-zero
  - **status:** active
  ```

  `kind: exception` blocks are declarations rather than promises: they name,
  via `target`, a piece of code that is intentionally duplicated or a known
  gap. They are checked for staleness (the target must still exist) but need
  no tagged test and do not count towards coverage.
  """

  @kinds %{
    "functional" => :functional,
    "non-functional" => :non_functional,
    "persisted-format" => :persisted_format,
    "ordering" => :ordering,
    "security" => :security,
    "exception" => :exception
  }

  @statuses %{"active" => :active, "retired" => :retired}

  @type kind ::
          :functional | :non_functional | :persisted_format | :ordering | :security | :exception
  @type status :: :active | :retired

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          component_id: String.t(),
          scope: String.t() | nil,
          must: String.t() | nil,
          why: String.t() | nil,
          kind: kind() | nil,
          record: String.t() | nil,
          status: status() | nil,
          target: String.t() | nil,
          fields: %{optional(String.t()) => String.t()},
          file: String.t(),
          line: pos_integer()
        }

  @enforce_keys [:id, :title, :component_id, :file, :line]
  defstruct [
    :id,
    :title,
    :component_id,
    :scope,
    :must,
    :why,
    :kind,
    :record,
    :status,
    :target,
    :file,
    :line,
    fields: %{}
  ]

  @doc "The accepted spellings of `kind`, as written in a block."
  @spec kind_names() :: [String.t()]
  def kind_names, do: Map.keys(@kinds) |> Enum.sort()

  @doc "Maps the written `kind` to its atom, or `nil` when unknown."
  @spec parse_kind(String.t()) :: kind() | nil
  def parse_kind(name), do: Map.get(@kinds, name)

  @doc "The accepted spellings of `status`."
  @spec status_names() :: [String.t()]
  def status_names, do: Map.keys(@statuses) |> Enum.sort()

  @doc "Maps the written `status` to its atom, or `nil` when unknown."
  @spec parse_status(String.t()) :: status() | nil
  def parse_status(name), do: Map.get(@statuses, name)

  @doc "True for `status: active` obligations."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "True for `kind: exception` declarations."
  @spec exception?(t()) :: boolean()
  def exception?(%__MODULE__{kind: :exception}), do: true
  def exception?(%__MODULE__{}), do: false

  @doc """
  True when the obligation is a promise that needs a tagged test: active and
  not an exception declaration.
  """
  @spec testable?(t()) :: boolean()
  def testable?(%__MODULE__{} = obligation),
    do: active?(obligation) and not exception?(obligation)

  @doc "Validates the `<component id>.I<n>` id shape."
  @spec valid_id?(String.t()) :: boolean()
  def valid_id?(id), do: Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\.I[1-9][0-9]*$/, id)

  @doc "The component id an obligation id belongs to (`\"a.b.I3\"` -> `\"a.b\"`)."
  @spec component_of(String.t()) :: String.t()
  def component_of(id), do: id |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")
end
