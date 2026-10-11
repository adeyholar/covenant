defmodule Vm.Hang do
  @moduledoc false

  # a mutant that negates `flag` leaves state behind (a persistent term) that outlives the
  # mutant's run: the suite then hangs in `setup_all`, in the unmutated re-run that follows
  def mark(flag), do: if(flag, do: :ok, else: :persistent_term.put({__MODULE__, :state}, :set))
end
