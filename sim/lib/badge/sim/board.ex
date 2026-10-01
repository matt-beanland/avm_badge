defmodule Badge.Sim.Board do
  @moduledoc """
  The processes a page finds on a badge: NVS, external-service fakes, real
  hardware owners over simulated drivers, the display and the real UI, all
  printing through an already running `Badge.Log` as they do on the badge.
  """

  use Supervisor

  alias Badge.Sim.Display
  alias Badge.Sim.Fakes
  alias Badge.Sim.Nvs

  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # The children inherit this, so every page print lands in the Log tab.
    Badge.Log.capture()

    hardware = [
      {Badge.Backlight, :ok},
      {Badge.Pixels, :sim_spi},
      {Badge.Sensors, :ok},
      {Badge.Power, :ok}
    ]

    children = [Nvs] ++ Fakes.children() ++ hardware ++ [Display, {Badge.UI, {Display, Display}}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Stops the badge, recompiles the project into the running VM, and starts the
  badge again on the new code. Every viewer gets `{:reloaded, result}` after.

  Compiler output goes through `Badge.Log`, so errors reach the Log tab. A
  failed compile leaves the badge off until a reload compiles. A reload asked
  for while another runs returns `:busy`.
  """
  def reload do
    try do
      Process.register(self(), Badge.Sim.Reload)
    rescue
      ArgumentError -> :busy
    else
      true ->
        Badge.Sim.log("sim: reloading")
        children = stop()

        result =
          try do
            recompile()
          catch
            kind, reason ->
              Badge.Sim.log("sim: " <> Exception.format(kind, reason, __STACKTRACE__))
              :error
          end

        case result do
          :error ->
            Badge.Sim.log("sim: compile failed, the badge stays off until a reload compiles")

          _ok_or_noop ->
            start(children)
        end

        Badge.Sim.Console.broadcast({:reloaded, result})
        Process.unregister(Badge.Sim.Reload)
        result
    end
  end

  defp recompile do
    mix? = Code.ensure_loaded?(Mix.Project) and Mix.Project.get() != nil

    case {mix?, Process.whereis(Badge.Log)} do
      {false, _log} ->
        :noop

      {true, nil} ->
        IEx.Helpers.recompile()

      {true, log} ->
        leader = Process.group_leader()
        stderr = Process.whereis(:standard_error)
        proxy = spawn(fn -> forward(log) end)
        Process.group_leader(self(), log)

        # Compile errors go to stderr, which the group leader never sees.
        try do
          Process.unregister(:standard_error)
          Process.register(proxy, :standard_error)
          IEx.Helpers.recompile()
        after
          if Process.whereis(:standard_error), do: Process.unregister(:standard_error)
          Process.register(stderr, :standard_error)
          send(proxy, :stop)
          Process.group_leader(self(), leader)
        end
    end
  end

  # Stands in for stderr: `Badge.Log` answers each request directly.
  defp forward(log) do
    receive do
      {:io_request, _from, _ref, _request} = request ->
        send(log, request)
        forward(log)

      :stop ->
        :ok
    end
  end

  @doc "Restarts everything except NVS, which is what a reboot keeps."
  def reboot do
    Badge.Sim.log("sim: reboot")
    start(stop())
    :ok
  end

  # Children in start order, all but NVS, stopped last first.
  defp stop do
    children =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(__MODULE__),
          id != Nvs,
          do: id

    for id <- children, do: :ok = Supervisor.terminate_child(__MODULE__, id)
    Enum.reverse(children)
  end

  defp start(children) do
    for id <- children, do: {:ok, _} = Supervisor.restart_child(__MODULE__, id)
  end
end
