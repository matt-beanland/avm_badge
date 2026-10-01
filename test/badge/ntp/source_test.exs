defmodule Badge.Ntp.SourceTest do
  use ExUnit.Case, async: true

  alias Badge.Ntp.Source

  defp sample(from, to, at \\ 0, delay \\ 100),
    do: %{offset: div(from + to, 2), delay: delay, root: 0, from: from, to: to, at: at}

  defp reply(source, result), do: Source.answered(%{source | busy: :q}, result, 0)

  test "a burst asks every 2 s before settling to the interval" do
    source = Source.new("pool", :external, 64_000, 2)

    assert Source.due?(source, 0)
    source = Source.asked(source, :q, 0)
    refute Source.due?(source, 1_000)
    assert source.due == 2_000

    source = Source.asked(%{source | busy: nil}, :q, 2_000)
    assert source.due == 4_000
    source = Source.asked(%{source | busy: nil}, :q, 4_000)
    assert source.due == 68_000
  end

  test "a source is not asked again while a query is in flight" do
    source = Source.asked(Source.new("gulou", :internal, 1_000), :q, 0)

    refute Source.due?(source, 5_000)
  end

  test "pending, then reachable, then unreachable after eight failures" do
    source = Source.new("gulou", :internal, 1_000)
    assert Source.status(source) == :pending

    source = reply(source, {:ok, sample(-10, 10)})
    assert Source.status(source) == :reachable

    source = Enum.reduce(1..7, source, fn _, acc -> reply(acc, {:error, :timeout}) end)
    assert Source.status(source) == :reachable

    source = reply(source, {:error, :timeout})
    assert Source.status(source) == :unreachable
    assert Source.best(source, 0) == nil
  end

  test "the best sample is the one with the lowest delay" do
    source =
      Source.new("gulou", :internal, 1_000)
      |> reply({:ok, sample(-30, 30, 0, 300)})
      |> reply({:ok, sample(-5, 5, 0, 50)})
      |> reply({:ok, sample(-20, 20, 0, 200)})

    assert %{from: -5, to: 5} = Source.best(source, 0)
  end

  test "the filter holds eight samples" do
    source =
      Enum.reduce(1..12, Source.new("gulou", :internal, 1_000), fn n, acc ->
        reply(acc, {:ok, sample(-n, n)})
      end)

    assert length(source.filter) == 8
  end

  test "a sample disjoint from the filter means the source stepped" do
    source =
      Source.new("gulou", :internal, 1_000)
      |> reply({:ok, sample(-5, 5, 0, 10)})
      |> reply({:ok, sample(-6, 6, 0, 12)})
      |> reply({:ok, sample(500_000, 500_010, 0, 900)})

    assert length(source.filter) == 1
    assert %{from: 500_000} = Source.best(source, 0)
  end

  test "a RATE kiss-of-death doubles the interval" do
    source = reply(Source.new("pool", :external, 64_000), {:error, {:kiss_of_death, "RATE"}})

    assert source.interval == 128_000
  end

  test "hurry brings the next query forward" do
    source = Source.asked(Source.new("pool", :external, 64_000), :q, 0)

    assert Source.hurry(source, 10_000).due == 10_000
  end

  test "addresses are labelled with their port, domains as they are" do
    assert Source.label(Source.new("192.168.1.50", :internal, 1_000)) == "192.168.1.50:123"
    assert Source.label(Source.new("time.google.com", :external, 64_000)) == "time.google.com"
  end
end
