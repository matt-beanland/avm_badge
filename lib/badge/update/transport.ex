defmodule Badge.Update.Transport do
  @moduledoc """
  The NervesHub agent's transport: `websocket_client` behind a relay process.

  The driver tags its messages with a term that is not the port `open/1` got
  back, and the agent drops every message whose handle is not the one it
  holds, `connected` included. So a relay opens the socket, owns it, and hands
  each message on to the agent as `{:websocket, relay, event}`; the relay's
  pid is the handle the agent holds.

  The relay closes the socket and exits when the agent closes it or exits.
  Pass it to the agent as `transport: Badge.Update.Transport`.
  """

  @compile {:no_warn_undefined, :websocket_client}

  @open_timeout 5_000

  @doc "Opens the socket on a relay reporting to the config's `owner`."
  @spec open(map, module) :: {:ok, pid} | {:error, term}
  def open(%{owner: owner} = config, client \\ :websocket_client) do
    caller = self()
    relay = spawn(fn -> start(caller, owner, config, client) end)
    ref = Process.monitor(relay)

    receive do
      {^relay, result} ->
        :erlang.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^relay, reason} ->
        {:error, {:relay, reason}}
    after
      @open_timeout ->
        :erlang.demonitor(ref, [:flush])
        Process.exit(relay, :kill)
        {:error, :open_timeout}
    end
  end

  @doc "Sends a text frame."
  @spec send_text(pid, iodata) :: :ok | {:error, term}
  def send_text(relay, data), do: call(relay, {:send_text, data})

  @doc "Closes the socket; a relay that is already gone counts as closed."
  @spec close(pid) :: :ok
  def close(relay) do
    call(relay, :close)
    :ok
  end

  defp start(caller, owner, config, client) do
    case client.open(%{config | owner: self()}) do
      {:ok, port} ->
        send(caller, {self(), {:ok, self()}})
        Process.monitor(owner)
        relay(port, owner, client)

      error ->
        send(caller, {self(), error})
    end
  end

  defp relay(port, owner, client) do
    receive do
      {:websocket, _driver, event} ->
        send(owner, {:websocket, self(), event})
        relay(port, owner, client)

      {{:send_text, data}, from, ref} ->
        send(from, {ref, client.send_text(port, data)})
        relay(port, owner, client)

      {:close, from, ref} ->
        client.close(port)
        send(from, {ref, :ok})

      {:DOWN, _ref, :process, ^owner, _reason} ->
        client.close(port)
    end
  end

  defp call(relay, request) do
    ref = Process.monitor(relay)
    send(relay, {request, self(), ref})

    receive do
      {^ref, reply} ->
        :erlang.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, _relay, _reason} ->
        {:error, :closed}
    end
  end
end
