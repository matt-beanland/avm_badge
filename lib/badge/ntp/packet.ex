defmodule Badge.Ntp.Packet do
  @moduledoc """
  The 48-byte NTPv4 client request and the server reply (RFC 5905).

  Times are microseconds since the Unix epoch, as
  `:erlang.system_time(:microsecond)` gives them. Every field is matched on a
  byte boundary; the packed leap, version and mode bits are taken apart with
  integer arithmetic.
  """

  import Bitwise

  # Seconds from 1900-01-01, the NTP era, to 1970-01-01.
  @era_offset 2_208_988_800

  # Leap 0, version 4, mode 3 (client).
  @client 0x23

  @doc "A client request carrying `sent` as its transmit timestamp."
  @spec request(integer) :: binary
  def request(sent) do
    <<@client, 0, 0, 0, 0::32, 0::32, 0::32, 0::64, 0::64, 0::64, to_ntp(sent)::64>>
  end

  @doc """
  The server's view of an exchange started by `request(sent)`.

  Returns `{:ok, %{received: t2, transmitted: t3, stratum: s, leap: l, root:
  r, ref_id: id}}`, where `root` is the server's root distance in
  microseconds (half its root delay plus its root dispersion), or
  an error for a reply that is short, not from a server, answers a different
  request, or is a kiss-of-death (stratum 0, with its four-letter code).
  """
  @spec parse(binary, integer) :: {:ok, map} | {:error, term}
  def parse(
        <<flags, stratum, _poll, _precision, root_delay::32, root_dispersion::32,
          ref_id::binary-4, _reference::64, origin::64, received::64, transmitted::64,
          _rest::binary>>,
        sent
      ) do
    cond do
      (flags &&& 7) != 4 -> {:error, :not_a_server_reply}
      stratum == 0 -> {:error, {:kiss_of_death, ref_id}}
      origin != to_ntp(sent) -> {:error, :wrong_origin}
      transmitted == 0 -> {:error, :no_transmit_time}
      true -> {:ok, reply(flags, stratum, received, transmitted, root_delay, root_dispersion, ref_id)}
    end
  end

  def parse(_packet, _sent), do: {:error, :short_packet}

  defp reply(flags, stratum, received, transmitted, root_delay, root_dispersion, ref_id) do
    %{
      received: from_ntp(received),
      transmitted: from_ntp(transmitted),
      stratum: stratum,
      leap: flags >>> 6,
      root: div(from_short(root_delay), 2) + from_short(root_dispersion),
      ref_id: ref_id
    }
  end

  @doc "A 32-bit NTP short value, 16.16 seconds, as microseconds."
  @spec from_short(non_neg_integer) :: non_neg_integer
  def from_short(short), do: (short * 1_000_000) >>> 16

  @doc "Microseconds since the Unix epoch as a 64-bit NTP timestamp."
  @spec to_ntp(integer) :: non_neg_integer
  def to_ntp(micros) do
    seconds = div(micros, 1_000_000)
    fraction = div(rem(micros, 1_000_000) <<< 32, 1_000_000)

    (seconds + @era_offset) <<< 32 ||| fraction
  end

  @doc "A 64-bit NTP timestamp as microseconds since the Unix epoch."
  @spec from_ntp(non_neg_integer) :: integer
  def from_ntp(timestamp) do
    seconds = (timestamp >>> 32) - @era_offset
    micros = ((timestamp &&& 0xFFFFFFFF) * 1_000_000) >>> 32

    seconds * 1_000_000 + micros
  end
end
