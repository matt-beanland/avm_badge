defmodule Badge.Schedule.AshConfTest do
  use ExUnit.Case, async: true

  alias Badge.Schedule
  alias Badge.Schedule.AshConf

  test "holds the compiled-in programme in timeline order" do
    entries = AshConf.entries()
    first = Schedule.unpack(Schedule.entry(entries, 0))
    last = Schedule.unpack(Schedule.entry(entries, tuple_size(entries) - 1))

    assert tuple_size(entries) == 11
    assert first.title == "Registration & Welcome"
    assert first.when == "Sat 3 Oct 09:45-10:15"
    assert first.where == "Large hall, AshConf 2026"
    assert last.title == "Closing Remarks"
    assert last.who == "Zach Daniel"
  end

  test "is always ready, and a retry does nothing" do
    assert %{state: :ready, reason: nil, held: true} = AshConf.status()
    assert AshConf.retry() == :ok
  end
end
