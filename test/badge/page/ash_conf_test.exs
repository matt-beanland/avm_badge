defmodule Badge.Page.AshConfTest do
  use ExUnit.Case, async: true

  alias Badge.Page.AshConf
  alias Badge.Page.Schedule, as: Timeline
  alias Badge.Schedule.AshConf, as: Source

  @day 1_440
  @axis :calendar.date_to_gregorian_days({2020, 1, 1})
  @saturday :calendar.date_to_gregorian_days({2026, 10, 3})

  defp at(hour, minute), do: (@saturday - @axis) * @day + hour * 60 + minute

  defp shown(now) do
    Timeline.apply_entries(Source.entries(), 1, AshConf.init())
    |> Timeline.apply_status(Source.status(), now)
  end

  defp texts(items), do: for({:text, _x, _y, _font, _fg, _bg, body} <- items, do: body)

  test "announces itself for the apps grid" do
    assert AshConf.title() == "AshConf"
    assert AshConf.icon() == :triangle
  end

  test "reads its programme from the AshConf source" do
    assert AshConf.init().source == Source
  end

  test "opens out the running talk" do
    texts = texts(AshConf.render(shown(at(11, 10))))

    assert "When Time Meets State" in texts
    assert "NOW 20m left" in texts
  end

  test "moves along the timeline" do
    {:ok, state} = AshConf.handle_key({:move, :down}, shown(at(11, 10)))

    assert "Ash Typescript" in texts(AshConf.render(state))
  end
end
