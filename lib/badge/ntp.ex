defmodule Badge.Ntp do
  @moduledoc """
  Asks NTP servers for the time and reports each answer as a
  `Badge.Ntp.Sample` against the system clock.

  `ask/2` spawns a process that queries one host and sends
  `{:ntp, ref, result}` to the owner, where a result is `{:ok, sample}` or
  `{:error, reason}`. The caller never waits on the network.

  `sources/1` builds the source list from the `ntp_hosts` setting: hosts
  separated by spaces, each optionally `host/seconds` for its poll interval.
  These are internal sources, polled every second by default, listed before
  the public servers.
  """

  alias Badge.Ntp.Packet
  alias Badge.Ntp.Sample
  alias Badge.Ntp.Source

  @compile {:no_warn_undefined, [:net]}

  @port 123
  @timeout 3_000

  @external ["time.cloudflare.com", "time.google.com", "se.pool.ntp.org"]
  @external_interval 64_000
  @external_burst 3
  @internal_interval 1_000
  @most 4

  @doc "Spawns a query of `host` that reports to `owner`; returns `{pid, ref}`."
  @spec ask(binary, pid) :: {pid, reference}
  def ask(host, owner) do
    ref = make_ref()
    pid = spawn(fn -> send(owner, {:ntp, ref, query(host)}) end)

    {pid, ref}
  end

  @doc "The sources for an `ntp_hosts` value, at most four, internal ones first."
  @spec sources(binary | nil) :: [Source.t()]
  def sources(setting) do
    internal = :lists.map(&internal/1, words(setting || <<>>))
    external = :lists.map(&Source.new(&1, :external, @external_interval, @external_burst), @external)

    :lists.sublist(internal ++ external, @most)
  end

  defp internal(word) do
    case :binary.split(word, "/") do
      [host, seconds] -> Source.new(host, :internal, interval(seconds))
      [host] -> Source.new(host, :internal, @internal_interval)
    end
  end

  defp interval(seconds) do
    case digits(:erlang.binary_to_list(seconds), 0) do
      n when n > 0 -> n * 1_000
      _bad -> @internal_interval
    end
  end

  defp digits([], acc), do: acc
  defp digits([char | rest], acc) when char >= ?0 and char <= ?9, do: digits(rest, acc * 10 + char - ?0)
  defp digits(_other, _acc), do: 0

  defp words(setting) do
    :lists.filter(&(&1 != <<>>), :binary.split(setting, [" ", "\n"], [:global]))
  end

  @doc "One exchange with `host`: `{:ok, sample}` or `{:error, reason}`."
  @spec query(binary) :: {:ok, Sample.t()} | {:error, term}
  def query(host) do
    with {:ok, address} <- resolve(host),
         {:ok, socket} <- :gen_udp.open(0, [:binary, {:active, false}]) do
      try do
        exchange(socket, address)
      after
        :gen_udp.close(socket)
      end
    end
  end

  defp exchange(socket, address) do
    sent = now()

    with :ok <- :gen_udp.send(socket, address, @port, Packet.request(sent)),
         {:ok, {_from, _port, reply}} <- :gen_udp.recv(socket, 0, @timeout),
         received = now(),
         {:ok, server} <- Packet.parse(reply, sent),
         :ok <- synchronised(server) do
      sample = Sample.new(sent, server.received, server.transmitted, received, server.root)
      {:ok, :maps.put(:stratum, server.stratum, sample)}
    end
  end

  defp synchronised(%{leap: 3}), do: {:error, :unsynchronised}
  defp synchronised(%{stratum: stratum}) when stratum >= 16, do: {:error, :unsynchronised}
  defp synchronised(_server), do: :ok

  defp now, do: :erlang.system_time(:microsecond)

  defp resolve(host) do
    case :net.getaddrinfo(:erlang.binary_to_list(host)) do
      {:ok, infos} -> ipv4(infos)
      {:error, reason} -> {:error, {:dns, reason}}
    end
  end

  defp ipv4([]), do: {:error, :no_ipv4_address}
  defp ipv4([%{family: :inet, addr: %{addr: address}} | _rest]), do: {:ok, address}
  defp ipv4([%{family: :inet, address: %{addr: address}} | _rest]), do: {:ok, address}
  defp ipv4([_other | rest]), do: ipv4(rest)
end
