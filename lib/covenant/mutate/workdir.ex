defmodule Covenant.Mutate.Workdir do
  @moduledoc """
  A private, throwaway copy of the project for one mutate worker.

  A mutant is the project's own code with one thing broken, and the worker
  runs it: a `string_empty` mutant that turns `@dir "tmp/cache"` into `""`
  makes a `File.rm_rf!(Path.expand(@dir))` in that code delete the working
  directory. So a worker never runs in the project root. It runs in a
  directory of its own (under `System.tmp_dir!/0` by default, named
  `covenant-mutate-<os pid>-<random suffix>`, created with an exclusive
  `File.mkdir/1` and mode 0700) that holds a real **copy** of every
  top-level entry of the project, so what a test or a mutant writes or
  deletes by a path relative to the working directory lands in the copy.
  The same directory keeps parallel workers from sharing ExUnit's `:tmp_dir`
  paths (`tmp/<module>/<test>` below the working directory).

  Not copied: a directory named `node_modules`, at any depth, and a directory
  named `_build` or `deps` whose parent directory holds a `mix.exs` (a Mix
  build or dependency tree: an umbrella app's `_build`, the root's `deps`;
  a `test/fixtures/deps` of plain data is copied like any directory), is a
  symlink to the project's (too big to copy; `File.rm_rf/1` does not follow a
  symlink, but a write through one reaches the project); `.git` and
  `.elixir_ls`, directory or file, are left out at any depth; at the top level
  `cover`, `doc`, `.lexical`, `.expert`, `erl_crash.dump` and `priv/plts`
  (dialyzer PLTs: hundreds of megabytes no test reads) are left out too; the
  top-level `tmp` is a fresh, empty directory. The base directory must not lie
  under the project root (a copy would copy itself): `build/3` raises
  `ArgumentError` when it does, except under the top-level `tmp/`, which is not
  copied.

  Symlinks are copied as symlinks, never followed, and never left pointing into
  the project: an absolute link whose target lies under the project root is
  rewritten to the same place under the workdir; a relative link that resolves
  outside the root (it would dangle in the copy) becomes an absolute link to
  the original target; a relative link that stays inside the root is copied
  as it is.

  Everything else is copied, ignored and untracked files included (the cost is
  about one copy of the tree per worker). `.git` is left out, so a test that
  shells out to `git` doesn't see the project's repository (git looks in the
  parent directories too: if the system temp directory lies inside some other
  repository, that one is what it sees) and its baseline will say so.

  An entry that cannot be read (`:eacces`: a mode-000 `data/pg` of an
  in-project Postgres volume, say) is left out with a warning on the standard
  error stream; any other failure removes the half-built directory and
  re-raises. `remove/1` makes the directories of the copy writable first (a
  test may leave a read-only one) and never raises.

  What this does **not** protect: absolute paths, paths reached through the
  `_build` and `deps` links, and paths derived from the project's location
  (`__DIR__`, `Application.app_dir/1`, a compiled-in `File.cwd!/0`) still
  point at the real project. `mix covenant.mutate` runs the project's own
  code against broken copies of it, so mutate a project whose tests you
  would run anyway, from a clean working tree.
  """

  @left_out ~w(.git .elixir_ls)
  # left out at the top level only (`priv/plts` is a path)
  @top_left_out ~w(cover doc .lexical .expert erl_crash.dump priv/plts)

  @doc """
  Creates the directory for the current OS process under `base` (the system
  temp directory by default) and returns its path. `suffix` (random by
  default) ends its name; a directory that already exists raises
  `File.Error` with reason `:eexist` and is never touched.
  """
  @spec build(Path.t(), Path.t(), String.t(), boolean()) :: Path.t()
  def build(root, base \\ System.tmp_dir!(), suffix \\ random_suffix(), register? \\ false) do
    root = Path.expand(root)
    check_base!(Path.expand(base), root)
    dir = Path.join(base, "covenant-mutate-#{System.pid()}-#{suffix}")

    File.mkdir!(dir)
    # with `register?` the stdin watcher of the task can find the directory, and
    # remove it, even when the parent dies while the tree is still being copied
    if register?, do: register(dir)

    try do
      File.chmod!(dir, 0o700)
      File.mkdir!(Path.join(dir, "tmp"))

      for entry <- File.ls!(root),
          entry not in ["tmp" | @left_out],
          not top_left_out?(root, entry) do
        copy(Path.join(root, entry), Path.join(dir, entry), root, dir)
      end

      dir
    rescue
      error ->
        remove(dir)
        if register?, do: unregister()
        reraise error, __STACKTRACE__
    end
  end

  @registry_key {__MODULE__, :registered}

  @doc "Registers `dir` as the private copy of this VM's worker (`registered/0`)."
  @spec register(Path.t()) :: :ok
  def register(dir), do: :persistent_term.put(@registry_key, dir)

  @doc "The directory registered by `register/1`, or `nil`."
  @spec registered() :: Path.t() | nil
  def registered, do: :persistent_term.get(@registry_key, nil)

  @doc "Forgets the registered directory."
  @spec unregister() :: :ok
  def unregister do
    :persistent_term.erase(@registry_key)
    :ok
  end

  @doc "Removes the registered directory, if there is one (see `remove/1`); it never raises."
  @spec remove_registered() :: :ok
  def remove_registered do
    with dir when is_binary(dir) <- registered(), do: remove(dir)
    :ok
  end

  # Directories named like a build or dependency tree are linked; a symlink is copied
  # as a symlink (see `link_target/4`), never followed; what is not a directory, a link
  # or a regular file (a socket, say) is left out; an entry the OS will not let us read
  # is left out with a warning.
  defp copy(source, target, root, dir) do
    case File.lstat!(source) do
      %File.Stat{type: :symlink} ->
        File.ln_s!(link_target(source, File.read_link!(source), root, dir), target)

      %File.Stat{type: :directory} ->
        if linked?(source) do
          File.ln_s!(source, target)
        else
          File.mkdir!(target)

          for entry <- File.ls!(source),
              entry not in @left_out,
              not top_left_out?(root, Path.relative_to(Path.join(source, entry), root)) do
            copy(Path.join(source, entry), Path.join(target, entry), root, dir)
          end
        end

      %File.Stat{type: :regular} ->
        File.cp!(source, target)

      _ ->
        :ok
    end
  rescue
    error in [File.Error, File.CopyError] ->
      if error.reason == :eacces do
        IO.puts(:stderr, "warning: mutate workdir: left out #{source}: permission denied")
        File.rm_rf(target)
        :ok
      else
        reraise error, __STACKTRACE__
      end
  end

  defp top_left_out?(_root, relative), do: relative in @top_left_out

  # A base under the root would be copied into itself, without end.
  defp check_base!(base, root) do
    case under(base, root) do
      :error ->
        :ok

      {:ok, relative} ->
        unless relative |> Path.split() |> List.first() == "tmp" do
          raise ArgumentError,
                "the base directory #{base} for the mutate workdir lies under the project " <>
                  "root #{root}, which it would copy into itself; set TMPDIR to a directory " <>
                  "outside the project (or under its top-level tmp/)"
        end
    end
  end

  defp linked?(source) do
    case Path.basename(source) do
      "node_modules" ->
        true

      name when name in ["_build", "deps"] ->
        File.regular?(Path.join(Path.dirname(source), "mix.exs"))

      _ ->
        false
    end
  end

  defp link_target(source, target, root, dir) do
    if Path.type(target) == :absolute do
      case under(target, root) do
        {:ok, relative} -> Path.join(dir, relative)
        :error -> target
      end
    else
      resolved = Path.expand(target, Path.dirname(source))
      if under(resolved, root) == :error, do: resolved, else: target
    end
  end

  defp under(path, root) do
    path = Path.expand(path)

    cond do
      path == root -> {:ok, ""}
      String.starts_with?(path, root <> "/") -> {:ok, Path.relative_to(path, root)}
      true -> :error
    end
  end

  @doc false
  @spec suffix() :: String.t()
  def suffix, do: random_suffix()

  defp random_suffix,
    do: 6 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)

  @doc """
  Removes the directory, if it is still there (a mutant may have deleted it).
  It never follows a symlink: the links go, never what they point at, whether
  they are at the top or inside a copied entry. A directory a test left
  read-only is made writable first, and nothing raises: what cannot be removed
  is reported on the standard error stream.
  """
  @spec remove(Path.t()) :: :ok
  def remove(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :symlink}} ->
        # the path was replaced by a link: the link goes, never what it points at
        File.rm(dir)

      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        # an unreadable top directory (mode 000) could be neither listed nor removed
        File.chmod(dir, Bitwise.bor(mode, 0o700))

        with {:ok, entries} <- File.ls(dir) do
          for entry <- entries,
              path = Path.join(dir, entry),
              match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) do
            File.rm(path)
          end
        end

        rm_rf(dir, 5)

      _ ->
        :ok
    end

    :ok
  end

  # A stray process of a mutant may be writing into the tree while it goes (the removal
  # then fails half way): try again a few times before giving up with a warning.
  defp rm_rf(dir, attempts) do
    make_writable(dir)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, _, _} when attempts > 1 ->
        Process.sleep(100)
        rm_rf(dir, attempts - 1)

      {:error, reason, path} ->
        IO.puts(
          :stderr,
          "warning: mutate workdir: could not remove #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  @doc """
  Makes every directory of the tree owner-writable (`u+rwx`), never following a
  symlink. The runner does it to the worker copy's `tmp/` before every suite run:
  ExUnit clears a test's `:tmp_dir` with `File.rm_rf!/1`, which fails on a
  directory an earlier run of the test left read-only.
  """
  @spec unlock(Path.t()) :: :ok
  def unlock(dir) do
    make_writable(dir)
    :ok
  end

  # `chmod u+rwx` on every real directory of the tree; a link is never followed.
  defp make_writable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        File.chmod(path, Bitwise.bor(mode, 0o700))

        with {:ok, entries} <- File.ls(path) do
          Enum.each(entries, &make_writable(Path.join(path, &1)))
        end

      _ ->
        :ok
    end
  end

  @doc """
  Removes the directory like `remove/1`, then leaves the process's working
  directory in a new, empty directory at the same path: a stray process of a
  mutant that still writes by a relative path fails with `:enoent` instead of
  writing anywhere that matters, and the VM still has a working directory.
  The runner calls it only when the VM is not about to halt: before a halt the
  removal alone is enough (a deleted working directory gives `:enoent` as well)
  and no empty directory is left behind.
  """
  @spec abandon(Path.t()) :: :ok
  def abandon(dir) do
    remove(dir)
    File.mkdir_p(dir)
    File.chmod(dir, 0o500)
    File.cd(dir)
    :ok
  end

  @doc "Runs `fun` with `dir` as the working directory, then restores the previous one."
  @spec within(Path.t(), (-> result)) :: result when result: var
  def within(dir, fun) do
    previous = File.cwd!()
    File.cd!(dir)

    try do
      fun.()
    after
      File.cd!(previous)
    end
  end
end
