defmodule Covenant.Mutate.Workdir do
  @moduledoc """
  A private working directory for one parallel mutate worker.

  ExUnit creates a test's `:tmp_dir` at `tmp/<module>/<test>` relative to the
  working directory of the OS process and offers no way to move it. Workers
  are OS processes running the same tests in one project, so without a
  directory of their own they would clear and rewrite each other's files, and
  the failures that follow would be credited as kills.

  A worker's directory (under `System.tmp_dir!/0`, named after the worker's OS
  pid) holds a symlink to every entry of the project root, so a relative path
  in a test resolves as it does in the project, except `tmp`, which is a real,
  empty directory: ExUnit's `:tmp_dir` paths and anything else a test writes
  below `tmp/` are the worker's alone.
  """

  @doc "Creates the directory for the current OS process and returns its path."
  @spec build(Path.t()) :: Path.t()
  def build(root) do
    root = Path.expand(root)
    dir = Path.join(System.tmp_dir!(), "covenant-mutate-#{System.pid()}")

    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "tmp"))

    for entry <- File.ls!(root), entry != "tmp" do
      File.ln_s!(Path.join(root, entry), Path.join(dir, entry))
    end

    dir
  end

  @doc "Removes the directory; the symlinks go, never what they point at."
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
