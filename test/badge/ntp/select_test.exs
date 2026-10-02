defmodule Badge.Ntp.SelectTest do
  use ExUnit.Case, async: true

  alias Badge.Ntp.Select

  doctest Badge.Ntp.Select

  defp at(id, from, to, extra \\ []), do: Map.merge(%{id: id, from: from, to: to}, Map.new(extra))

  test "no sources is unsynced" do
    selection = Select.select([])

    assert selection.status == :unsynced
    assert selection.reason == :no_sources
    assert selection.result == nil
  end

  test "a single source is a majority of one" do
    selection = Select.select([at(:gulou, -500, 501)])

    assert selection.status == :synced
    assert selection.result == %{from: -500, to: 501}
    assert {selection.size, selection.count} == {1, 1}
    assert selection.chimers == [:gulou]
  end

  test "the result is where the agreeing sources overlap" do
    selection = Select.select([at(:a, 0, 100), at(:b, 20, 80), at(:c, 50, 200)])

    assert selection.result == %{from: 50, to: 80}
    assert selection.chimers == [:a, :b, :c]
    assert selection.tickers == []
  end

  test "a source that agrees with no majority is a falseticker" do
    selection = Select.select([at(:a, 0, 100), at(:b, 20, 80), at(:c, 50, 200), at(:d, 900, 950)])

    assert selection.result == %{from: 50, to: 80}
    assert selection.tickers == [:d]
    assert {selection.size, selection.count} == {3, 4}
  end

  test "ranges that only meet do not agree" do
    selection = Select.select([at(:a, 0, 10), at(:b, 10, 20)])

    assert selection.status == :unsynced
    assert selection.reason == :no_majority
  end

  test "half is not a majority" do
    selection = Select.select([at(:a, 0, 10), at(:b, 5, 15), at(:c, 100, 110), at(:d, 105, 115)])

    assert selection.reason == :no_majority
    assert selection.size == 2
  end

  test "two majorities that do not overlap are contested" do
    selection = Select.select([at(:a, 0, 10), at(:b, 5, 15), at(:c, 12, 20)])

    assert selection.status == :unsynced
    assert selection.reason == :contested
  end

  test "majority beats precision" do
    selection =
      Select.select([
        at(:gulou, 0, 2, stratum: 1),
        at(:a, 10, 100, stratum: 2),
        at(:b, 20, 90, stratum: 2),
        at(:c, 5, 60, stratum: 3)
      ])

    assert selection.tickers == [:gulou]
    assert selection.result == %{from: 20, to: 60}
  end

  test "the system peer is the truechimer with the lowest stratum, then the narrowest interval" do
    selection =
      Select.select([
        at(:a, 0, 100, stratum: 2, root: 50),
        at(:b, 10, 90, stratum: 1, root: 900),
        at(:c, 20, 80, stratum: 1, root: 300)
      ])

    assert selection.peer.id == :c
  end

  test "a near stratum 1 beats a far one that reports a smaller root distance" do
    selection =
      Select.select([
        at(:google, -56_000, 28_000, stratum: 1, root: 0),
        at(:gulou, -12_640, 12_640, stratum: 1, root: 37)
      ])

    assert selection.peer.id == :gulou
  end
end
