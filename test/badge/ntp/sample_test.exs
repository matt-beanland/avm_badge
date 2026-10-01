defmodule Badge.Ntp.SampleTest do
  use ExUnit.Case, async: true

  alias Badge.Ntp.Sample

  doctest Badge.Ntp.Sample

  test "offset and delay follow RFC 5905" do
    # Server 50 ms ahead, 10 ms each way, 2 ms turnaround.
    sample = Sample.new(0, 60_000, 62_000, 22_000)

    assert sample.offset == 50_000
    assert sample.delay == 20_000
    assert {sample.from, sample.to} == {40_000, 60_001}
    assert sample.at == 22_000
  end

  test "the server's root distance widens the interval" do
    sample = Sample.new(0, 60_000, 62_000, 22_000, 3_000)

    assert {sample.from, sample.to} == {37_000, 63_001}
  end

  test "a sample widens by 15 ppm of its age" do
    sample = Sample.new(0, 60_000, 62_000, 22_000)

    assert Sample.age(sample, 22_000) == %{from: 40_000, to: 60_001}
    assert Sample.age(sample, 22_000 + 100_000_000) == %{from: 38_500, to: 61_501}
  end

  test "a sample from the future does not shrink" do
    sample = Sample.new(0, 60_000, 62_000, 22_000)

    assert Sample.age(sample, 0) == %{from: 40_000, to: 60_001}
  end
end
