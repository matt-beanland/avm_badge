defmodule Badge.Ntp.Source do
  @moduledoc """
  One clock the badge asks for the time: when to ask next, whether it is
  answering, and its last eight samples.

  `kind` is `:internal` or `:external`, set by configuration. Times passed as
  `now` to the scheduling functions are monotonic milliseconds; those passed
  to `best/2` and `answered/3` are system microseconds.

  The 8-bit `reach` register shifts in a 1 for every answer and a 0 for every
  failure, so a source is unreachable after eight polls without an answer.
  The filter keeps the lowest-delay sample, and is flushed when a new sample
  no longer meets the old ones: the source has stepped.
  """

  import Bitwise

  alias Badge.Allen
  alias Badge.Ntp.Sample

  @filter 8
  @burst_gap 2_000
  @port 123
  @disjoint [:precedes, :meets, :met_by, :preceded_by]

  @type t :: map

  @doc "A source that is due at once, then `burst` more times 2 s apart, then every `interval` ms."
  @spec new(binary, :internal | :external, pos_integer, non_neg_integer) :: t
  def new(host, kind, interval, burst \\ 0) do
    %{
      host: host,
      kind: kind,
      interval: interval,
      burst: burst,
      due: 0,
      busy: nil,
      reach: 0,
      filter: [],
      last: nil
    }
  end

  @doc "Whether the source should be asked at monotonic time `now`."
  @spec due?(t, integer) :: boolean
  def due?(source, now), do: source.busy == nil and now >= source.due

  @doc "Records that a query is in flight, held as `busy`, and schedules the next."
  @spec asked(t, term, integer) :: t
  def asked(source, busy, now) do
    gap = if source.burst > 0, do: @burst_gap, else: source.interval

    %{source | busy: busy, due: now + gap, burst: max(source.burst - 1, 0)}
  end

  @doc "Brings the next query forward to `now`."
  @spec hurry(t, integer) :: t
  def hurry(source, now), do: %{source | due: min(source.due, now)}

  @doc "Records the result of the query in flight, at system time `now`."
  @spec answered(t, {:ok, Sample.t()} | {:error, term}, integer) :: t
  def answered(source, {:ok, sample}, now) do
    kept =
      case lowest(source.filter) do
        nil ->
          []

        old ->
          if :lists.member(Allen.relation(sample, Sample.age(old, now)), @disjoint),
            do: [],
            else: source.filter
      end

    %{
      source
      | busy: nil,
        reach: shift(source.reach, 1),
        filter: :lists.sublist([sample | kept], @filter),
        last: :ok
    }
  end

  def answered(source, {:error, {:kiss_of_death, "RATE"}} = error, _now) do
    %{failed(source, error) | interval: source.interval * 2}
  end

  def answered(source, error, _now), do: failed(source, error)

  @doc "`:pending` before the first result, `:unreachable` after eight failures, else `:reachable`."
  @spec status(t) :: :pending | :unreachable | :reachable
  def status(%{last: nil}), do: :pending
  def status(%{reach: 0}), do: :unreachable
  def status(_source), do: :reachable

  @doc "The lowest-delay sample, aged to system time `now`, or nil when the source cannot vote."
  @spec best(t, integer) :: map | nil
  def best(source, now) do
    case {status(source), lowest(source.filter)} do
      {:reachable, sample} when sample != nil -> :maps.merge(sample, Sample.age(sample, now))
      _other -> nil
    end
  end

  @doc "How the source is named on the panel: a domain as it is, an address with its port."
  @spec label(t) :: binary
  def label(%{host: host}) do
    if address?(host), do: host <> ":" <> :erlang.integer_to_binary(@port), else: host
  end

  defp failed(source, error) do
    %{source | busy: nil, reach: shift(source.reach, 0), last: error}
  end

  defp shift(reach, bit), do: (reach <<< 1 ||| bit) &&& 0xFF

  defp lowest([]), do: nil

  defp lowest([first | rest]) do
    :lists.foldl(fn sample, best -> if sample.delay < best.delay, do: sample, else: best end, first, rest)
  end

  defp address?(host) do
    :lists.all(fn char -> char == ?. or (char >= ?0 and char <= ?9) end, :erlang.binary_to_list(host))
  end
end
