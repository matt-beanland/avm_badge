defmodule Badge.Page.NtpTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Ntp

  doctest Badge.Page.Ntp

  @cloudflare "time.cloudflare.com"
  @google "time.google.com"
  @pool "se.pool.ntp.org"

  defp texts(state), do: for({:text, _x, _y, _f, _fg, _bg, text} <- Ntp.render(state), do: text)

  defp sample(state, from, to, stratum \\ 2) do
    %{
      offset: div(from + to, 2),
      delay: to - from,
      root: 0,
      from: from,
      to: to,
      at: state.now,
      stratum: stratum
    }
  end

  defp answer(state, host, result) do
    ref = make_ref()

    sources =
      Enum.map(state.sources, fn
        %{host: ^host} = source -> %{source | busy: {self(), ref}}
        source -> source
      end)

    {:ok, state} = Ntp.handle_info({:ntp, ref, result}, %{state | sources: sources})
    state
  end

  defp answered(answers) do
    state = Ntp.init()

    Enum.reduce(answers, state, fn
      {host, {:error, _reason} = error}, acc -> answer(acc, host, error)
      {host, {from, to}}, acc -> answer(acc, host, {:ok, sample(acc, from, to)})
    end)
  end

  defp row(state, label), do: Enum.find_index(texts(state), &(&1 == label))

  test "every source shows as asking until it answers, and the local clock as unknown" do
    text = texts(Ntp.init())

    assert Enum.count(text, &(&1 == "asking...")) == 3
    assert "unknown" in text
    assert "unsynced 0/0 of 3" in text
  end

  test "an answer shows its bounds around the claimed time" do
    state = answered([{@cloudflare, {-1_000, 1_000}}])
    text = texts(state)

    assert "-1.00 +1.00ms" in text
    assert Badge.Text.cp437("synced 1/1 of 3 st3 ±1.00ms") in text
  end

  test "agreeing sources are truechimers and the result is their overlap" do
    state =
      answered([
        {@cloudflare, {-4_000, 2_000}},
        {@google, {-2_000, 4_000}},
        {@pool, {-3_000, 3_000}}
      ])

    text = texts(state)

    assert Badge.Text.cp437("synced 3/3 st3 ±2.00ms") in text
    assert Enum.count(text, &(&1 in ["*", "+"])) == 3
  end

  test "a source the majority disagrees with is a falseticker, drawn hollow" do
    state =
      answered([
        {@cloudflare, {-1_000, 1_000}},
        {@google, {-1_500, 900}},
        {@pool, {80_000, 90_000}}
      ])

    text = texts(state)

    assert "x" in text
    assert Badge.Text.cp437("synced 2/3 st3 ±0.95ms") in text
    assert "P" in text
  end

  test "contested majorities are unsynced" do
    state =
      answered([
        {@cloudflare, {0, 10_000}},
        {@google, {5_000, 15_000}},
        {@pool, {12_000, 20_000}}
      ])

    assert "unsynced 2/3 contested" in texts(state)
  end

  test "a failed source shows why, and is not counted" do
    state = answered([{@cloudflare, {-1_000, 1_000}}, {@pool, {:error, :timeout}}])
    text = texts(state)

    assert "timeout" in text
    assert Badge.Text.cp437("synced 1/1 of 3 st3 ±1.00ms") in text
  end

  test "rows run in timeline order" do
    state =
      answered([
        {@cloudflare, {5_000, 9_000}},
        {@google, {-9_000, -5_000}},
        {@pool, {-1_000, 1_000}}
      ])

    assert row(state, @google) < row(state, @pool)
    assert row(state, @pool) < row(state, @cloudflare)
  end

  test "a known local clock sits on the axis with its relation to the result" do
    state = %{answered([{@cloudflare, {-1_000, 1_000}}]) | local: :known}
    text = texts(state)

    refute "unknown" in text
    assert "d" in text
    assert "+0.00ms" in text
  end

  test "messages for queries it did not make are ignored" do
    assert Ntp.handle_info({:ntp, make_ref(), {:error, :timeout}}, Ntp.init()) == :ignore
  end

  test "R brings the public servers forward, at most every 16 s" do
    state = %{
      Ntp.init()
      | mono: 100_000,
        sources: Enum.map(Ntp.init().sources, &%{&1 | due: 200_000})
    }

    {:ok, hurried} = Ntp.handle_key({:char, ?r}, state)
    assert Enum.all?(hurried.sources, &(&1.due == 100_000))

    {:ok, again} = Ntp.handle_key({:char, ?R}, %{hurried | mono: 110_000, sources: state.sources})
    assert Enum.all?(again.sources, &(&1.due == 200_000))
  end

  test "keeps every text row inside the panel" do
    state =
      answered([{@cloudflare, {-56 * 31_557_600_000_000, 1_000}}, {@google, {-2_000, 4_000}}])

    for {:text, x, _y, :default16px, _fg, _bg, text} <- Ntp.render(state) do
      assert x + 8 * byte_size(text) <= 320, "#{inspect(text)} at #{x}"
    end
  end

  test "P turns the panic threshold off for the visit, and back on" do
    assert Enum.any?(texts(Ntp.init()), &String.contains?(&1, "panic on"))

    {:ok, off} = Ntp.handle_key({:char, ?p}, Ntp.init())
    assert Enum.any?(texts(off), &String.contains?(&1, "panic off"))

    {:ok, on} = Ntp.handle_key({:char, ?P}, off)
    assert on.discipline.panic
  end

  test "a spike or a refused step is noted after the conviction" do
    state = answered([{@cloudflare, {199_000, 201_000}}])

    assert Enum.any?(texts(%{state | note: :spike}), &String.ends_with?(&1, "ms spike"))
    assert Enum.any?(texts(%{state | note: :panic}), &String.ends_with?(&1, "ms panic"))
  end

  test "a clock the page set widens from its error at 15 ppm" do
    state = answered([{@cloudflare, {-5_000, 5_000}}])
    set = %{state | local: %{at: state.now - 100_000_000, error: 1_000}}

    assert "-2.50 +2.50ms" in texts(set)
  end

  test "times read as UTC to the millisecond" do
    assert Ntp.stamp(1_790_000_000_123_456) == "14:13:20.123Z"
    assert Ntp.stamp(5_000) == "00:00:00.005Z"
  end
end
