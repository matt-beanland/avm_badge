defmodule Badge.Ntp.Scale do
  @moduledoc """
  The NTP page's fixed time axis: linear over ±20 ms around the centre, then
  one equal step per decade out to 10^16 µs (about 300 years), clamped
  beyond. It never rescales.

  `x/1` maps an offset in microseconds to a panel column. `place/1` maps a
  set of offsets so that any two distinct ones land at least a pixel apart,
  keeping the drawn order of endpoints, and so every Allen relation, true.
  """

  @left 8
  @right 312
  @centre div(@left + @right, 2)
  @half @centre - @left
  @inner 60
  @linear 20_000
  @first_decade 4
  @last_decade 16

  # {µs, pixels from the centre}: the linear zone's edge, then one row per decade.
  @decades [{@linear, @inner}] ++
             for(
               k <- (@first_decade + 1)..@last_decade,
               do:
                 {Integer.pow(10, k),
                  @inner +
                    div((k - @first_decade) * (@half - @inner), @last_decade - @first_decade)}
             )

  @ticks [{"1s", 1_000_000}, {"1h", 3_600_000_000}, {"1y", 31_557_600_000_000}]

  @doc "The column at the centre of the axis."
  def centre, do: @centre

  @doc "The leftmost and rightmost columns of the axis."
  def bounds, do: {@left, @right}

  @doc "Labelled ticks as `{label, µs}`, drawn either side of the centre."
  def ticks, do: @ticks

  @doc "The column for an offset of `micros` from the centre."
  @spec x(integer) :: integer
  def x(micros) when micros < 0, do: @centre - distance(-micros)
  def x(micros), do: @centre + distance(micros)

  @doc "Columns for every offset in `values`, strictly increasing over distinct values."
  @spec place([integer]) :: %{integer => integer}
  def place(values) do
    {placed, _last} =
      :lists.foldl(
        fn value, {acc, last} ->
          column = max(x(value), last + 1)
          {:maps.put(value, column, acc), column}
        end,
        {%{}, @left - 1},
        :lists.usort(values)
      )

    placed
  end

  defp distance(micros) when micros <= @linear, do: div(micros * @inner, @linear)
  defp distance(micros), do: decade(micros, @decades)

  defp decade(_micros, [{_at, column}]), do: column

  defp decade(micros, [{low, low_x}, {high, high_x} | _rest]) when micros < high do
    low_x + div((micros - low) * (high_x - low_x), high - low)
  end

  defp decade(micros, [_passed | rest]), do: decade(micros, rest)
end
