defmodule Badge.Ntp.Discipline do
  @moduledoc """
  Decides, once a second, what to do to the system clock given a selection.

  The offset is the midpoint of the selected result, in microseconds.

  - A local clock that has never been set is stepped at once.
  - An offset of 128 ms or more is a spike until it has lasted 10 s, then a
    step. With the panic threshold on, one beyond it (1000 s unless set
    otherwise) is refused instead.
  - A smaller offset is slewed, at most 500 µs per decision, while the
    local clock lies outside the result; inside it, nothing is done.

  `decide/4` returns the action and the next state: `:none`, `:spike` (a
  spike has just begun), `:wait`, `:panic`, `{:step, micros}` or
  `{:slew, micros}`.
  """

  alias Badge.Allen

  @step 128_000
  @stepout 10_000
  @panic 1_000_000_000
  @slew 500
  @inside [:during, :starts, :finishes, :equals]

  @type t :: %{spike: integer | nil, panic: boolean, limit: pos_integer}
  @type action :: :none | :spike | :wait | :panic | {:step, integer} | {:slew, integer}

  @doc """
  No spike in progress, with a panic threshold of `seconds`, off when 0.

  An `ntp_panic` setting is the threshold as a decimal number of seconds;
  `threshold/1` reads one, giving 1000 for nil or anything malformed.
  """
  @spec new(non_neg_integer) :: t
  def new(seconds \\ 1_000) do
    %{spike: nil, panic: seconds > 0, limit: max(seconds, 1) * 1_000_000}
  end

  @doc "The panic threshold in seconds for an `ntp_panic` setting."
  @spec threshold(binary | nil) :: non_neg_integer
  def threshold(nil), do: div(@panic, 1_000_000)

  def threshold(setting) do
    chars = :erlang.binary_to_list(setting)

    if chars != [] and :lists.all(&(&1 >= ?0 and &1 <= ?9), chars),
      do: :lists.foldl(&(&2 * 10 + &1 - ?0), 0, chars),
      else: div(@panic, 1_000_000)
  end

  @doc "Turns the panic threshold off, or back on."
  @spec toggle_panic(t) :: t
  def toggle_panic(discipline), do: %{discipline | panic: not discipline.panic}

  @doc "The action for `selection`, given whether the local clock was ever set, at monotonic `now` ms."
  @spec decide(t, map, boolean, integer) :: {action, t}
  def decide(discipline, %{status: :synced, result: result}, set?, now) do
    offset = div(result.from + result.to, 2)
    calm = %{discipline | spike: nil}

    cond do
      not set? -> {{:step, offset}, calm}
      abs(offset) < @step -> {slew(offset, result), calm}
      discipline.panic and abs(offset) > discipline.limit -> {:panic, calm}
      discipline.spike == nil -> {:spike, %{discipline | spike: now}}
      now - discipline.spike >= @stepout -> {{:step, offset}, calm}
      true -> {:wait, discipline}
    end
  end

  def decide(discipline, _unsynced, _set?, _now), do: {:none, %{discipline | spike: nil}}

  defp slew(offset, result) do
    if :lists.member(Allen.relation(%{from: 0, to: 1}, result), @inside),
      do: :none,
      else: {:slew, max(-@slew, min(@slew, offset))}
  end
end
