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

  Not copied: `_build`, `deps` and `node_modules` are symlinks to the
  project's (too big to copy; `File.rm_rf!/1` does not follow a symlink, but
  a write through one reaches the project); `.git` and `.elixir_ls` are left
  out; `tmp` is a fresh, empty directory.

  What this does **not** protect: absolute paths, paths reached through the
  `_build` and `deps` links, and paths derived from the project's location
  (`__DIR__`, `Application.app_dir/1`, a compiled-in `File.cwd!/0`) still
  point at the real project. `mix covenant.mutate` runs the project's own
  code against broken copies of it, so mutate a project whose tests you
  would run anyway, from a clean working tree.
  """

  @linked ~w(_build deps node_modules)
  @left_out ~w(.git .elixir_ls tmp)

  @doc """
  Creates the directory for the current OS process under `base` (the system
  temp directory by default) and returns its path. `suffix` (random by
  default) ends its name; a directory that already exists raises
  `File.Error` with reason `:eexist` and is never touched.
  """
  @spec build(Path.t(), Path.t(), String.t()) :: Path.t()
  def build(root, base \\ System.tmp_dir!(), suffix \\ random_suffix()) do
    root = Path.expand(root)
    dir = Path.join(base, "covenant-mutate-#{System.pid()}-#{suffix}")

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    File.mkdir!(Path.join(dir, "tmp"))

    for entry <- File.ls!(root), entry not in @left_out do
      source = Path.join(root, entry)
      target = Path.join(dir, entry)

      if entry in @linked,
        do: File.ln_s!(source, target),
        else: File.cp_r!(source, target)
    end

    dir
  end

  defp random_suffix,
    do: 6 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)

  @doc """
  Removes the directory. It never follows a symlink: the links go, never what
  they point at, whether they are at the top or inside a copied entry.
  """
  @spec remove(Path.t()) :: :ok
  def remove(dir) do
    for entry <- File.ls!(dir),
        path = Path.join(dir, entry),
        match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) do
      File.rm!(path)
    end

    File.rm_rf!(dir)
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
