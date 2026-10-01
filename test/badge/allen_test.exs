defmodule Badge.AllenTest do
  use ExUnit.Case, async: true

  alias Badge.Allen

  doctest Badge.Allen

  defp at(minute), do: NaiveDateTime.add(~N[2026-10-01 09:00:00], minute * 60)
  defp span(from, to), do: %{from: at(from), to: at(to)}

  describe "relation/2" do
    test "names all 13 relations against [10, 20)" do
      y = span(10, 20)

      cases = [
        {span(0, 5), :precedes},
        {span(0, 10), :meets},
        {span(5, 15), :overlaps},
        {span(5, 20), :finished_by},
        {span(5, 25), :contains},
        {span(10, 15), :starts},
        {span(10, 20), :equals},
        {span(10, 25), :started_by},
        {span(12, 18), :during},
        {span(15, 20), :finishes},
        {span(15, 25), :overlapped_by},
        {span(20, 25), :met_by},
        {span(25, 30), :preceded_by}
      ]

      for {x, expected} <- cases do
        assert Allen.relation(x, y) == expected
        assert Allen.relation(y, x) == Allen.inverse(expected)
      end
    end

    test "tells microseconds apart" do
      a = %{from: ~N[2026-10-01 09:00:00.000000], to: ~N[2026-10-01 09:00:00.000001]}
      b = %{from: ~N[2026-10-01 09:00:00.000001], to: ~N[2026-10-01 09:00:01.000000]}

      assert Allen.relation(a, b) == :meets
    end

    test "takes integers on any scale" do
      assert Allen.relation(%{from: 1, to: 3}, %{from: 2, to: 4}) == :overlaps
    end

    test "refuses an interval that does not end after it starts" do
      empty = span(10, 10)

      assert Allen.relation(empty, span(0, 5)) == {:error, {:empty_interval, empty}}
      assert Allen.relation(span(0, 5), empty) == {:error, {:empty_interval, empty}}
    end
  end

  describe "compose/2" do
    test "matches Tempo's examples" do
      assert Allen.compose(:precedes, :during) == [:precedes, :meets, :overlaps, :starts, :during]
      assert Allen.compose(:equals, :overlaps) == [:overlaps]

      assert Allen.compose(:contains, :during) ==
               [
                 :overlaps,
                 :finished_by,
                 :contains,
                 :starts,
                 :equals,
                 :started_by,
                 :during,
                 :finishes,
                 :overlapped_by
               ]
    end

    test "matches Allen's published cells" do
      assert Allen.compose(:meets, :met_by) == [:finished_by, :equals, :finishes]
      assert Allen.compose(:starts, :started_by) == [:starts, :equals, :started_by]
      assert Allen.compose(:precedes, :preceded_by) == Allen.full()

      assert Allen.compose(:meets, :preceded_by) ==
               [:contains, :started_by, :overlapped_by, :met_by, :preceded_by]
    end

    test "equals is the identity on both sides" do
      for r <- Allen.full() do
        assert Allen.compose(:equals, r) == [r]
        assert Allen.compose(r, :equals) == [r]
      end
    end

    test "agrees with the inverse: converse(r1 . r2) is inverse(r2) . inverse(r1)" do
      for r1 <- Allen.full(), r2 <- Allen.full() do
        assert Allen.converse(Allen.compose(r1, r2)) ==
                 Allen.compose(Allen.inverse(r2), Allen.inverse(r1))
      end
    end

    test "lifts to sets as the union of cells" do
      assert Allen.compose([:precedes, :meets], [:starts]) == [:precedes, :meets]
    end

    test "rejects anything that is not a relation" do
      assert Allen.compose(:precedes, :nonsense) == {:error, {:invalid_relation, :nonsense}}
    end
  end

  describe "sets" do
    test "converse, narrow and canonical keep Allen's order" do
      assert Allen.converse([:precedes, :meets]) == [:met_by, :preceded_by]
      assert Allen.narrow([:meets, :precedes], [:overlaps, :meets]) == [:meets]
      assert Allen.canonical([:during, :precedes, :during]) == [:precedes, :during]
    end

    test "masks round-trip" do
      assert Allen.from_mask(Allen.to_mask(Allen.full())) == Allen.full()
      assert Allen.to_mask(Allen.full()) == Allen.full_mask()
      assert Allen.from_mask(0) == []
    end
  end
end
