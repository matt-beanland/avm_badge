defmodule Badge.Clock.Keeper do
  @moduledoc """
  Keeps the last known wall time in NVS, so a badge that boots without wifi
  carries on from where it was instead of from 1970.

  Once a minute it saves `now/0` under the `clock` key. Until SNTP sets the
  system clock, `now/0` is the saved time moved on by this boot's uptime, so
  it runs behind by however long the badge was switched off.
  """

  use GenServer

  alias Badge.Clock
  alias Badge.Nvs
  alias Badge.Schedule

  @key :clock
  @tick 60_000

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "UTC seconds: the system clock once set, else the saved estimate, else the unset clock."
  @spec now() :: integer
  def now, do: GenServer.call(__MODULE__, :now)

  @impl true
  def init(:ok) do
    start_ticker()

    {:ok, %{base: Clock.restore(Nvs.get(@key), uptime())}}
  end

  @impl true
  def handle_call(:now, _from, state), do: {:reply, reading(state), state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    save(reading(state))

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reading(state), do: Clock.estimate(:erlang.system_time(:second), uptime(), state.base)

  defp uptime, do: div(:erlang.monotonic_time(:millisecond), 1000)

  defp save(seconds) do
    case Schedule.clock_set?(seconds) do
      true -> store(:erlang.integer_to_binary(seconds))
      false -> :ok
    end
  end

  defp store(value) do
    case Nvs.put(@key, value) do
      :ok -> :ok
      error -> :io.format(~c"Clock: save failed ~p~n", [error])
    end
  end

  # Waits in a linked process, so this GenServer never sleeps in a callback.
  defp start_ticker do
    keeper = self()

    spawn_link(fn -> tick_loop(keeper) end)
  end

  defp tick_loop(keeper) do
    Process.sleep(@tick)
    send(keeper, :tick)
    tick_loop(keeper)
  end
end
