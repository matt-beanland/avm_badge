defmodule Badge.Update.TransportTest do
  use ExUnit.Case, async: true

  alias Badge.Update.Transport

  # Stands in for `websocket_client`: tags messages with a term that is not
  # the port it hands back, as the driver does.
  defmodule Client do
    def open(%{owner: owner, test: test}) do
      port = spawn(fn -> socket(test) end)
      send(owner, {:websocket, :driver_term, :connected})
      send(test, {:opened, port, owner})
      {:ok, port}
    end

    def open(%{refuse: reason}), do: {:error, reason}

    def send_text(port, data) do
      send(port, {:sent, data})
      :ok
    end

    def close(port) do
      send(port, :closed)
      :ok
    end

    defp socket(test) do
      receive do
        {:sent, data} ->
          send(test, {:sent, self(), data})
          socket(test)

        :closed ->
          send(test, {:closed, self()})
      end
    end
  end

  defp open, do: Transport.open(%{owner: self(), test: self()}, Client)

  test "the agent hears the driver's messages under the handle it was given" do
    {:ok, relay} = open()

    assert_receive {:opened, _port, ^relay}
    assert_receive {:websocket, ^relay, :connected}
  end

  test "sends and closes go to the socket the relay owns" do
    {:ok, relay} = open()
    assert_receive {:opened, port, _relay}

    assert Transport.send_text(relay, "frame") == :ok
    assert_receive {:sent, ^port, "frame"}

    ref = Process.monitor(relay)
    assert Transport.close(relay) == :ok
    assert_receive {:closed, ^port}
    assert_receive {:DOWN, ^ref, :process, ^relay, _reason}
  end

  test "a closed relay refuses sends and closes quietly" do
    {:ok, relay} = open()
    Transport.close(relay)

    assert Transport.send_text(relay, "late") == {:error, :closed}
    assert Transport.close(relay) == :ok
  end

  test "a refused open is passed on" do
    assert Transport.open(%{owner: self(), refuse: :nxdomain}, Client) == {:error, :nxdomain}
  end

  test "the socket closes when the agent exits" do
    test = self()

    agent =
      spawn(fn ->
        {:ok, relay} = Transport.open(%{owner: self(), test: test}, Client)
        send(test, {:relay, relay})
        Process.sleep(:infinity)
      end)

    assert_receive {:opened, port, _relay}
    Process.exit(agent, :kill)

    assert_receive {:closed, ^port}
  end
end
