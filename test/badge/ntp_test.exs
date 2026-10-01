defmodule Badge.NtpTest do
  use ExUnit.Case, async: true

  alias Badge.Ntp

  test "without ntp_hosts the public servers are the sources" do
    sources = Ntp.sources(nil)

    assert Enum.map(sources, & &1.host) == ["time.cloudflare.com", "time.google.com", "se.pool.ntp.org"]
    assert Enum.all?(sources, &(&1.kind == :external and &1.interval == 64_000 and &1.burst == 3))
  end

  test "ntp_hosts come first as internal sources, polled every second" do
    [gulou | rest] = Ntp.sources("192.168.1.50")

    assert {gulou.host, gulou.kind, gulou.interval, gulou.burst} == {"192.168.1.50", :internal, 1_000, 0}
    assert length(rest) == 3
  end

  test "an interval can follow a slash, and a bad one falls back to a second" do
    [a, b | _] = Ntp.sources("gulou.local/5  10.0.0.2/x")

    assert {a.host, a.interval} == {"gulou.local", 5_000}
    assert {b.host, b.interval} == {"10.0.0.2", 1_000}
  end

  test "at most four sources" do
    assert length(Ntp.sources("a b c")) == 4
  end
end
