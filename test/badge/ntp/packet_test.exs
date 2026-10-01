defmodule Badge.Ntp.PacketTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Badge.Ntp.Packet

  @sent 1_790_000_000_123_456

  defp reply(overrides \\ []) do
    o = Map.new(overrides)
    flags = Map.get(o, :flags, 0x24)
    stratum = Map.get(o, :stratum, 2)
    origin = Map.get(o, :origin, Packet.to_ntp(@sent))
    received = Map.get(o, :received, Packet.to_ntp(@sent + 400))
    transmitted = Map.get(o, :transmitted, Packet.to_ntp(@sent + 420))
    root_delay = Map.get(o, :root_delay, 0)
    root_dispersion = Map.get(o, :root_dispersion, 0)

    <<flags, stratum, 6, 0xE9, root_delay::32, root_dispersion::32, "GOOG", 0::64, origin::64,
      received::64, transmitted::64>>
  end

  test "a request is 48 bytes, version 4, client mode, carrying its send time" do
    request = Packet.request(@sent)

    assert byte_size(request) == 48
    <<flags, _::binary-39, transmit::64>> = request
    assert flags >>> 6 == 0
    assert (flags >>> 3 &&& 7) == 4
    assert (flags &&& 7) == 3
    assert transmit == Packet.to_ntp(@sent)
  end

  test "timestamps round-trip to the microsecond" do
    for micros <- [0, 1, 999_999, @sent, 4_102_444_800_000_000] do
      assert Packet.from_ntp(Packet.to_ntp(micros)) in [micros, micros - 1]
    end

    assert Packet.from_ntp(Packet.to_ntp(@sent)) >= @sent - 1
  end

  test "the Unix epoch is 2,208,988,800 seconds into the NTP era" do
    assert Packet.to_ntp(0) == 2_208_988_800 <<< 32
  end

  test "parses a server reply" do
    assert {:ok, server} = Packet.parse(reply(), @sent)

    assert server.stratum == 2
    assert server.leap == 0
    assert_in_delta server.received, @sent + 400, 1
    assert_in_delta server.transmitted, @sent + 420, 1
    assert server.ref_id == "GOOG"
  end

  test "root distance is half the root delay plus the root dispersion" do
    # 0x0001_0000 is one second; 0x0000_8000 half of one.
    {:ok, server} = Packet.parse(reply(root_delay: 0x0000_8000, root_dispersion: 0x0001_0000), @sent)

    assert server.root == 250_000 + 1_000_000
  end

  test "refuses what is not a usable answer" do
    assert Packet.parse(reply(flags: 0x23), @sent) == {:error, :not_a_server_reply}
    assert Packet.parse(reply(stratum: 0), @sent) == {:error, {:kiss_of_death, "GOOG"}}
    assert Packet.parse(reply(origin: 1), @sent) == {:error, :wrong_origin}
    assert Packet.parse(reply(transmitted: 0), @sent) == {:error, :no_transmit_time}
    assert Packet.parse(<<0x24, 1, 2>>, @sent) == {:error, :short_packet}
  end
end
