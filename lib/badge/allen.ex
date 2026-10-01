defmodule Badge.Allen do
  @moduledoc """
  Allen's interval algebra on half-open `[from, to)` intervals, following
  Tempo's `Tempo.Interval` and `Tempo.Interval.Relations`.

  An interval is `%{from: t, to: t}` where `t` is a `NaiveDateTime`, read as
  UTC, or an integer on any one scale. `relation/2` names the single relation
  between two intervals. A set of relations is a list in Allen's canonical
  order; `compose/2`, `converse/1` and `narrow/2` work on sets.

  Sets are also available as 13-bit masks (`to_mask/1`, `from_mask/1`,
  `compose_mask/2`, `converse_mask/1`), which `Badge.Allen.Network` uses.

      iex> a = %{from: ~N[2026-10-01 09:00:00], to: ~N[2026-10-01 10:00:00]}
      iex> b = %{from: ~N[2026-10-01 09:30:00], to: ~N[2026-10-01 11:00:00]}
      iex> Badge.Allen.relation(a, b)
      :overlaps
  """

  import Bitwise

  alias Badge.Allen.Order

  @relations Order.relations()
  @full (1 <<< length(@relations)) - 1

  @inverse %{
    precedes: :preceded_by,
    meets: :met_by,
    overlaps: :overlapped_by,
    finished_by: :finishes,
    contains: :during,
    starts: :started_by,
    equals: :equals,
    started_by: :starts,
    during: :contains,
    finishes: :finished_by,
    overlapped_by: :overlaps,
    met_by: :meets,
    preceded_by: :precedes
  }

  # Every arrangement of three intervals on six points, A r1 B and B r2 C giving A r3 C.
  @table (
           index = @relations |> Enum.with_index() |> Map.new()
           spans = for from <- 0..5, to <- (from + 1)..5//1, do: {from, to}

           cells =
             for {a1, a2} <- spans, {b1, b2} <- spans, {c1, c2} <- spans, reduce: %{} do
               cells ->
                 key = {Order.classify(a1, a2, b1, b2), Order.classify(b1, b2, c1, c2)}
                 bit = 1 <<< index[Order.classify(a1, a2, c1, c2)]
                 Map.update(cells, key, bit, &(&1 ||| bit))
             end

           @relations
           |> Enum.map(fn r1 -> @relations |> Enum.map(&cells[{r1, &1}]) |> List.to_tuple() end)
           |> List.to_tuple()
         )

  @converse (
              index = @relations |> Enum.with_index() |> Map.new()
              @relations |> Enum.map(&index[@inverse[&1]]) |> List.to_tuple()
            )

  @type relation :: atom
  @type interval :: %{from: term, to: term}

  @doc "The 13 relations in Allen's canonical order."
  @spec full() :: [relation]
  def full, do: @relations

  @doc """
  The relation from `a` to `b`.

  Returns `{:error, {:empty_interval, interval}}` when an interval does not
  end after it starts.
  """
  @spec relation(interval, interval) :: relation | {:error, term}
  def relation(%{from: a_from, to: a_to} = a, %{from: b_from, to: b_to} = b) do
    a1 = point(a_from)
    a2 = point(a_to)
    b1 = point(b_from)
    b2 = point(b_to)

    cond do
      a2 <= a1 -> {:error, {:empty_interval, a}}
      b2 <= b1 -> {:error, {:empty_interval, b}}
      true -> Order.classify(a1, a2, b1, b2)
    end
  end

  @doc "A `NaiveDateTime` as microseconds since year 0, or an integer unchanged."
  @spec point(term) :: integer
  def point(value) when is_integer(value), do: value

  def point(%{
        __struct__: NaiveDateTime,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second,
        microsecond: {micro, _precision}
      }) do
    seconds = :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}})
    seconds * 1_000_000 + micro
  end

  @doc "The inverse relation: if `relation(a, b)` is `r`, `relation(b, a)` is `inverse(r)`."
  @spec inverse(relation) :: relation
  def inverse(relation), do: :maps.get(relation, @inverse)

  @doc """
  The relations possible from A to C given A `r1` B and B `r2` C.

  Takes two relations or two sets, and returns a set in canonical order.
  """
  @spec compose(relation | [relation], relation | [relation]) ::
          [relation] | {:error, {:invalid_relation, term}}
  def compose(r1, r2) when is_atom(r1), do: compose([r1], r2)
  def compose(r1, r2) when is_atom(r2), do: compose(r1, [r2])

  def compose(r1, r2) do
    with m1 when is_integer(m1) <- to_mask(r1),
         m2 when is_integer(m2) <- to_mask(r2) do
      from_mask(compose_mask(m1, m2))
    end
  end

  @doc "The converse of a set: each relation replaced by its inverse."
  @spec converse([relation]) :: [relation] | {:error, {:invalid_relation, term}}
  def converse(relations) do
    with mask when is_integer(mask) <- to_mask(relations) do
      from_mask(converse_mask(mask))
    end
  end

  @doc "The relations in both sets."
  @spec narrow([relation], [relation]) :: [relation] | {:error, {:invalid_relation, term}}
  def narrow(r1, r2) do
    with m1 when is_integer(m1) <- to_mask(r1),
         m2 when is_integer(m2) <- to_mask(r2) do
      from_mask(m1 &&& m2)
    end
  end

  @doc "A set in canonical order, or the first entry that is not a relation."
  @spec canonical([term]) :: [relation] | {:error, {:invalid_relation, term}}
  def canonical(relations) do
    with mask when is_integer(mask) <- to_mask(relations), do: from_mask(mask)
  end

  @doc "The mask holding every relation."
  @spec full_mask() :: non_neg_integer
  def full_mask, do: @full

  @doc "A set as a 13-bit mask, bit `i` for the `i`th relation in canonical order."
  @spec to_mask([term]) :: non_neg_integer | {:error, {:invalid_relation, term}}
  def to_mask(relations), do: to_mask(relations, 0)

  defp to_mask([], mask), do: mask

  defp to_mask([relation | rest], mask) do
    case bit(relation) do
      0 -> {:error, {:invalid_relation, relation}}
      bit -> to_mask(rest, mask ||| bit)
    end
  end

  @doc "A mask as a set in canonical order."
  @spec from_mask(non_neg_integer) :: [relation]
  def from_mask(mask), do: from_mask(mask, @relations, [])

  defp from_mask(0, _relations, acc), do: :lists.reverse(acc)
  defp from_mask(_mask, [], acc), do: :lists.reverse(acc)

  defp from_mask(mask, [relation | rest], acc) when (mask &&& 1) == 1,
    do: from_mask(mask >>> 1, rest, [relation | acc])

  defp from_mask(mask, [_relation | rest], acc), do: from_mask(mask >>> 1, rest, acc)

  @doc "`compose/2` on masks."
  @spec compose_mask(non_neg_integer, non_neg_integer) :: non_neg_integer
  def compose_mask(m1, m2), do: compose_rows(m1, 0, m2, 0)

  defp compose_rows(0, _i, _m2, acc), do: acc

  defp compose_rows(m1, i, m2, acc) when (m1 &&& 1) == 1,
    do: compose_rows(m1 >>> 1, i + 1, m2, compose_cells(elem(@table, i), m2, 0, acc))

  defp compose_rows(m1, i, m2, acc), do: compose_rows(m1 >>> 1, i + 1, m2, acc)

  defp compose_cells(_row, 0, _j, acc), do: acc

  defp compose_cells(row, m2, j, acc) when (m2 &&& 1) == 1,
    do: compose_cells(row, m2 >>> 1, j + 1, acc ||| elem(row, j))

  defp compose_cells(row, m2, j, acc), do: compose_cells(row, m2 >>> 1, j + 1, acc)

  @doc "`converse/1` on masks."
  @spec converse_mask(non_neg_integer) :: non_neg_integer
  def converse_mask(mask), do: converse_mask(mask, 0, 0)

  defp converse_mask(0, _i, acc), do: acc

  defp converse_mask(mask, i, acc) when (mask &&& 1) == 1,
    do: converse_mask(mask >>> 1, i + 1, acc ||| 1 <<< elem(@converse, i))

  defp converse_mask(mask, i, acc), do: converse_mask(mask >>> 1, i + 1, acc)

  for {relation, i} <- Enum.with_index(@relations) do
    defp bit(unquote(relation)), do: unquote(1 <<< i)
  end

  defp bit(_other), do: 0
end
