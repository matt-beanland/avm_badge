defmodule Badge.Page.AshConf do
  @moduledoc """
  The AshConf programme: `Badge.Page.Schedule` reading from
  `Badge.Schedule.AshConf` instead of the main programme.
  """

  use Badge.Page

  alias Badge.Page.Schedule

  @impl true
  def title, do: "AshConf"

  @impl true
  def icon, do: :triangle

  @impl true
  def init, do: Schedule.init(Badge.Schedule.AshConf)

  @impl true
  def tick(state), do: Schedule.tick(state)

  @impl true
  def render(state), do: Schedule.render(state)

  @impl true
  def handle_key(event, state), do: Schedule.handle_key(event, state)
end
