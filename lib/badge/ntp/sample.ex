defmodule Badge.Ntp.Sample do
  @moduledoc """
  One NTP exchange as an interval of possible clock offsets.

  With `t1` sent and `t4` received on the system clock, and `t2`, `t3` the
  server's receive and transmit times, the offset `server - system` is
  `θ = ((t2 - t1) + (t3 - t4)) / 2` and the round trip is
  `δ = (t4 - t1) - (t3 - t2)`. The true offset lies within
  `θ ± (δ/2 + root)`, where `root` is the server's own root distance, so a
  sample is the half-open interval `[θ - e, θ + e + 1)` in microseconds.

  A sample grows less certain as it ages: `age/2` widens it by 15 ppm of the
  time since it was taken.

      iex> sample = Badge.Ntp.Sample.new(1_000, 1_500, 1_520, 1_100)
      iex> {sample.offset, sample.delay, sample.from, sample.to}
      {460, 80, 420, 501}
  """

  @phi_ppm 15

  @type t :: %{
          offset: integer,
          delay: non_neg_integer,
          root: non_neg_integer,
          from: integer,
          to: integer,
          at: integer
        }

  @doc "A sample from the four timestamps of one exchange and the server's root distance, in µs."
  @spec new(integer, integer, integer, integer, non_neg_integer) :: t
  def new(t1, t2, t3, t4, root \\ 0) do
    offset = div(t2 - t1 + (t3 - t4), 2)
    delay = max(t4 - t1 - (t3 - t2), 0)
    error = div(delay, 2) + root

    %{offset: offset, delay: delay, root: root, from: offset - error, to: offset + error + 1, at: t4}
  end

  @doc "The sample's interval at system time `now`, widened by 15 ppm of its age."
  @spec age(t, integer) :: %{from: integer, to: integer}
  def age(sample, now) do
    grown = div(max(now - sample.at, 0) * @phi_ppm, 1_000_000)

    %{from: sample.from - grown, to: sample.to + grown}
  end
end
