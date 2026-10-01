defmodule Badge.Ntp.ScaleTest do
  use ExUnit.Case, async: true

  alias Badge.Ntp.Scale

  test "zero is the centre" do
    assert Scale.x(0) == Scale.centre()
  end

  test "the middle is linear over ±10 ms" do
    assert Scale.x(5_000) - Scale.centre() == 30
    assert Scale.x(10_000) - Scale.centre() == 60
    assert Scale.centre() - Scale.x(-10_000) == 60
  end

  test "it is symmetric and never decreasing out to the edges" do
    offsets = [0, 1, 999, 10_000, 10_001, 1_000_000, 3_600_000_000, 1_000_000_000_000_000]

    columns = Enum.map(offsets, &Scale.x/1)
    assert columns == Enum.sort(columns)

    assert Enum.map(offsets, &(Scale.centre() - Scale.x(-&1))) ==
             Enum.map(columns, &(&1 - Scale.centre()))
  end

  test "1970 seen from 2026 fits on the panel" do
    {left, right} = Scale.bounds()
    years = -56 * 31_557_600_000_000

    assert Scale.x(years) >= left
    assert Scale.x(-years) <= right
    assert Scale.x(-1_000_000_000_000_000_000) == left
  end

  test "distinct offsets are placed at least a pixel apart, in order" do
    placed = Scale.place([0, 1, 2, -1, 50_000_000])

    assert placed[-1] < placed[0]
    assert placed[0] < placed[1]
    assert placed[1] < placed[2]
    assert placed[2] < placed[50_000_000]
  end

  test "equal offsets share a column" do
    assert map_size(Scale.place([7, 7, 7])) == 1
  end
end
