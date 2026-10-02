defmodule Badge.Schedule.AshConf do
  @moduledoc """
  The AshConf programme, a source for `Badge.Page.Schedule`.

  `assets/ashconf-2026-schedule.json` is parsed on the host and packed in.
  Nothing is fetched, so it is always ready.
  """

  alias Badge.Page
  alias Badge.Schedule

  @source Path.expand("../../../assets/ashconf-2026-schedule.json", __DIR__)
  @external_resource @source

  @packed (case Schedule.parse(File.read!(@source), Page.Schedule.columns()) do
             {:ok, sessions} -> :erlang.term_to_binary(Schedule.pack(sessions))
             :error -> raise "assets/ashconf-2026-schedule.json is not a programme"
           end)

  @doc "Always ready, holding the compiled-in programme."
  @spec status() :: map
  def status, do: %{state: :ready, reason: nil, version: 1, held: true}

  @doc "The programme, as entries in timeline order."
  @spec entries() :: Schedule.entries()
  def entries, do: :erlang.binary_to_term(@packed)

  @doc "Nothing to retry."
  @spec retry() :: :ok
  def retry, do: :ok
end
