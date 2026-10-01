defmodule Badge.Ntp.Select do
  @moduledoc """
  Marzullo's intersection over sources' offset intervals, in Allen relations.

  An entry is a map with `:id`, `:from`, `:to`, and optionally `:stratum` and
  `:root`. A candidate group is every entry covering one entry's lower bound
  (`D S F e` to the instant `[from, from + 1)`). The largest group must be a
  majority, and no other group may be as large; the result is the
  intersection of its intervals.

  Truechimers are the entries the result lies within (`s e d f` from the
  result); falsetickers are disjoint from it. The system peer is the
  truechimer with the lowest stratum, then the shortest root distance.

      iex> a = %{id: :a, from: 0, to: 10}
      iex> b = %{id: :b, from: 4, to: 12}
      iex> c = %{id: :c, from: 30, to: 40}
      iex> selection = Badge.Ntp.Select.select([a, b, c])
      iex> {selection.status, selection.result, selection.tickers}
      {:synced, %{from: 4, to: 10}, [:c]}
  """

  alias Badge.Allen

  @covers [:contains, :started_by, :finished_by, :equals]
  @inside [:starts, :equals, :during, :finishes]

  @type selection :: %{
          status: :synced | :unsynced,
          reason: :no_sources | :no_majority | :contested | nil,
          result: %{from: integer, to: integer} | nil,
          size: non_neg_integer,
          count: non_neg_integer,
          chimers: [term],
          tickers: [term],
          peer: map | nil
        }

  @doc "Selects among `entries`."
  @spec select([map]) :: selection
  def select([]), do: unsynced(:no_sources, 0, 0)

  def select(entries) do
    groups = :lists.usort(:lists.map(fn entry -> group(entry, entries) end, entries))
    size = :lists.foldl(fn ids, acc -> max(length(ids), acc) end, 0, groups)
    largest = :lists.filter(fn ids -> length(ids) == size end, groups)
    count = length(entries)

    cond do
      2 * size <= count -> unsynced(:no_majority, size, count)
      length(largest) > 1 -> unsynced(:contested, size, count)
      true -> synced(hd(largest), entries, size, count)
    end
  end

  defp group(entry, entries) do
    instant = %{from: entry.from, to: entry.from + 1}

    covering = :lists.filter(&:lists.member(Allen.relation(&1, instant), @covers), entries)

    :lists.sort(:lists.map(& &1.id, covering))
  end

  defp synced(ids, entries, size, count) do
    [first | rest] = :lists.filter(&:lists.member(&1.id, ids), entries)
    result = :lists.foldl(&intersect/2, %{from: first.from, to: first.to}, rest)
    inside? = &:lists.member(Allen.relation(result, &1), @inside)
    chimers = :lists.filter(inside?, entries)
    tickers = :lists.filter(&(not inside?.(&1)), entries)

    %{
      status: :synced,
      reason: nil,
      result: result,
      size: size,
      count: count,
      chimers: :lists.map(& &1.id, chimers),
      tickers: :lists.map(& &1.id, tickers),
      peer: peer(chimers)
    }
  end

  defp unsynced(reason, size, count) do
    %{
      status: :unsynced,
      reason: reason,
      result: nil,
      size: size,
      count: count,
      chimers: [],
      tickers: [],
      peer: nil
    }
  end

  defp intersect(entry, acc), do: %{from: max(acc.from, entry.from), to: min(acc.to, entry.to)}

  defp peer([first | rest]) do
    :lists.foldl(
      fn entry, best -> if rank(entry) < rank(best), do: entry, else: best end,
      first,
      rest
    )
  end

  defp rank(entry), do: {:maps.get(:stratum, entry, 16), :maps.get(:root, entry, 0)}
end
