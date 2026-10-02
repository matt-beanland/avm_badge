defmodule Badge.Ntp.DisciplineTest do
  use ExUnit.Case, async: true

  alias Badge.Ntp.Discipline

  defp synced(from, to), do: %{status: :synced, result: %{from: from, to: to}}

  test "an unset local clock is stepped at once, however far" do
    assert {{:step, 1_780_000_000_000_000}, _} =
             Discipline.decide(
               Discipline.new(),
               synced(1_780_000_000_000_000 - 5, 1_780_000_000_000_000 + 5),
               false,
               0
             )
  end

  test "nothing is done while unsynced" do
    assert {:none, _} = Discipline.decide(Discipline.new(), %{status: :unsynced}, true, 0)
  end

  test "a local clock inside the result is left alone" do
    assert {:none, _} = Discipline.decide(Discipline.new(), synced(-2_000, 3_000), true, 0)
  end

  test "a small offset is slewed, at most 1 ms at a time" do
    assert {{:slew, 1_000}, _} =
             Discipline.decide(Discipline.new(), synced(9_000, 11_000), true, 0)

    assert {{:slew, -300}, _} = Discipline.decide(Discipline.new(), synced(-310, -290), true, 0)
  end

  test "slews come at most every 2 s" do
    {{:slew, 1_000}, d} = Discipline.decide(Discipline.new(), synced(9_000, 11_000), true, 10_000)

    assert {:none, d} = Discipline.decide(d, synced(8_000, 10_000), true, 11_000)
    assert {{:slew, 1_000}, _} = Discipline.decide(d, synced(8_000, 10_000), true, 12_000)
  end

  test "a large offset is a spike for 10 s, then a step" do
    {:spike, d} = Discipline.decide(Discipline.new(), synced(199_000, 201_000), true, 1_000)
    {:wait, d} = Discipline.decide(d, synced(199_000, 201_000), true, 6_000)

    assert {{:step, 200_000}, %{spike: nil}} =
             Discipline.decide(d, synced(199_000, 201_000), true, 11_000)
  end

  test "a spike that goes away is forgotten" do
    {:spike, d} = Discipline.decide(Discipline.new(), synced(199_000, 201_000), true, 1_000)
    {_slew, d} = Discipline.decide(d, synced(-100, 100), true, 2_000)

    assert {:spike, _} = Discipline.decide(d, synced(199_000, 201_000), true, 3_000)
  end

  test "over 1000 s is refused while the panic threshold is on" do
    far = synced(2_000_000_000, 2_000_000_100)

    assert {:panic, _} = Discipline.decide(Discipline.new(), far, true, 0)

    off = Discipline.toggle_panic(Discipline.new())
    assert {:spike, _} = Discipline.decide(off, far, true, 0)
  end

  test "the threshold can be set, or turned off with 0" do
    assert {:panic, _} =
             Discipline.decide(Discipline.new(60), synced(90_000_000, 90_000_100), true, 0)

    assert {:spike, _} =
             Discipline.decide(Discipline.new(0), synced(2_000_000_000, 2_000_000_100), true, 0)

    refute Discipline.new(0).panic
  end

  test "an ntp_panic setting is seconds, falling back to 1000" do
    assert Discipline.threshold("60") == 60
    assert Discipline.threshold("0") == 0
    assert Discipline.threshold(nil) == 1_000
    assert Discipline.threshold("soon") == 1_000
    assert Discipline.threshold("") == 1_000
  end
end
