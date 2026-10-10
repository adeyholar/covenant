defmodule Example.CounterContractTest do
  use Covenant.Case, component: "example.counter", async: true

  alias Example.Counter

  @starts [0, 1, 5, 100]
  @steps [1, 2, 10, 1_000]

  @tag obligation: "example.counter.I1"
  test "decrementing past zero stops at zero, never negative, never raising" do
    for start <- @starts, by <- @steps do
      counter = at(start) |> Counter.decrement(by)
      assert Counter.value(counter) == max(start - by, 0)
      assert Counter.value(counter) >= 0
    end
  end

  @tag obligation: "example.counter.I2"
  test "a zero, negative or non-integer step raises and leaves no event" do
    counter = at(3)

    for bad <- [0, -1, 1.5, nil, "1", :one] do
      assert_raise ArgumentError, fn -> Counter.increment(counter, bad) end
      assert_raise ArgumentError, fn -> Counter.decrement(counter, bad) end
    end

    assert Counter.events(counter) == [{:incremented, 3}]
  end

  # Persists through a file in ExUnit's :tmp_dir, which covenant.tasks.I7 uses
  # to check that parallel `mix covenant.mutate` workers never share one: when
  # COVENANT_TMPDIR_LOG names a file, the test appends "<os pid> <tmp_dir>" to it.
  @tag obligation: "example.counter.I3"
  @tag :tmp_dir
  test "the persisted form has exactly the keys value and max", %{tmp_dir: dir} do
    if log = System.get_env("COVENANT_TMPDIR_LOG") do
      File.write!(log, "#{System.pid()} #{dir}\n", [:append])
    end

    file = Path.join(dir, "counter.term")

    for start <- @starts, max <- [1, 100, 1_000] do
      File.write!(
        file,
        Counter.new(max: max) |> step(start) |> Counter.to_map() |> :erlang.term_to_binary()
      )

      map = file |> File.read!() |> :erlang.binary_to_term()
      assert Map.keys(map) |> Enum.sort() == ["max", "value"]
      assert map["max"] == max
      assert map["value"] == min(start, max)
    end
  end

  @tag obligation: "example.counter.I4"
  test "events are listed oldest first, one per successful call" do
    counter =
      Counter.new(max: 10) |> Counter.increment(2) |> Counter.increment(3) |> Counter.decrement(1)

    assert Counter.events(counter) == [{:incremented, 2}, {:incremented, 3}, {:decremented, 1}]
  end

  @tag obligation: ["example.counter.I1", "example.counter.I4"]
  test "the worked example: clamps record a clamped event in call order" do
    counter =
      Counter.new(max: 3) |> Counter.increment(2) |> Counter.increment(2) |> Counter.decrement(5)

    assert Counter.value(counter) == 0
    assert Counter.events(counter) == [{:incremented, 2}, {:clamped, :max}, {:clamped, :zero}]
  end

  @tag obligation: "example.counter.I6"
  test "a step that lands exactly on a bound is recorded as a step, not a clamp" do
    for max <- [1, 3, 100] do
      up = Counter.new(max: max) |> Counter.increment(max)
      assert Counter.value(up) == max
      assert Counter.events(up) == [{:incremented, max}]

      down = Counter.decrement(up, max)
      assert Counter.value(down) == 0
      assert Counter.events(down) == [{:incremented, max}, {:decremented, max}]
    end
  end

  @tag obligation: "example.counter.I7"
  test "a counter built without max: has a cap of 100" do
    assert Counter.to_map(Counter.new())["max"] == 100
    assert Counter.to_map(Counter.new([]))["max"] == 100
    assert Counter.new() |> Counter.increment(1_000) |> Counter.value() == 100
  end

  defp at(0), do: Counter.new()
  defp at(value), do: Counter.new() |> Counter.increment(value)

  defp step(counter, 0), do: counter
  defp step(counter, by), do: Counter.increment(counter, by)
end
