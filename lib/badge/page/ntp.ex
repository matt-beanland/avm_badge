defmodule Badge.Page.Ntp do
  @moduledoc """
  The badge as an NTP client: sources on top, the claimed time below.

  Each source row shows its tally code (`*` system peer, `+` truechimer,
  `x` falseticker, `?` unreachable), the Allen relation from its interval to
  the result, its name and the bounds of its interval, with the interval
  drawn on a fixed axis centred on the claimed time. Internal sources come
  from the `ntp_hosts` setting and are drawn in the select colour, public
  servers in the muted one; falsetickers are hollow. The local clock is the
  first row, labelled with the node name.

  Below the axis, the claimed time in UTC, its bounds, and the conviction:
  synced or not, the agreeing sources out of those answering (and out of
  those configured, when some are silent), the badge's stratum and the
  bound. R polls the public servers again, at most once every 16 s.

  While the page is open it disciplines the system clock once a second, as
  `Badge.Ntp.Discipline` decides: a step through
  `:atomvm.posix_clock_settime/2`, or a slew of at most 500 µs. A step
  clears every source's samples and tells `Badge.Wifi` the clock is set; a
  slew moves them with the clock. The panic threshold comes from the
  `ntp_panic` setting, in seconds; P turns it off or on for the visit.
  """

  use Badge.Page

  @compile {:no_warn_undefined, :atomvm}

  alias Badge.Allen
  alias Badge.Clock
  alias Badge.Nav
  alias Badge.Ntp
  alias Badge.Ntp.Discipline
  alias Badge.Ntp.Scale
  alias Badge.Ntp.Select
  alias Badge.Ntp.Source
  alias Badge.Nvs
  alias Badge.Readout
  alias Badge.Text
  alias Badge.Theme
  alias Badge.Wifi

  @top Theme.content_top()
  @pitch 24
  @bar_dy 17
  @bar_h 5
  @axis_y 148
  @out_y 169
  @out_bar_y 186
  @verdict_y 194
  @help_y 216
  @char_w 8
  @columns 38
  @wifi_every 60_000
  @resync_gap 16_000
  @discipline_every 1_000
  @phi_ppm 15

  @impl true
  def title, do: "NTP"

  @impl true
  def icon, do: :circle

  @impl true
  def init do
    %{
      sources: Ntp.sources(nil),
      ready: false,
      node: "local",
      local: :unknown,
      wifi_at: nil,
      resync_at: nil,
      discipline: Discipline.new(),
      disciplined_at: nil,
      note: nil,
      now: :erlang.system_time(:microsecond),
      mono: 0
    }
  end

  @impl true
  def tick(state) do
    mono = :erlang.monotonic_time(:millisecond)

    %{state | mono: mono, now: :erlang.system_time(:microsecond)}
    |> configure()
    |> check_wifi(mono)
    |> ask(mono)
    |> discipline(mono)
  end

  @impl true
  def refresh(_state), do: 250

  @impl true
  def handle_info({:ntp, ref, result}, state) do
    case :lists.any(&match?({_pid, ^ref}, &1.busy), state.sources) do
      true ->
        now = :erlang.system_time(:microsecond)

        sources =
          :lists.map(
            fn
              %{busy: {_pid, ^ref}} = source -> Source.answered(source, result, now)
              source -> source
            end,
            state.sources
          )

        {:ok, %{state | sources: sources}}

      false ->
        :ignore
    end
  end

  def handle_info(_message, _state), do: :ignore

  @impl true
  def handle_key({:char, char}, state) when char == ?r or char == ?R do
    if state.resync_at == nil or state.mono - state.resync_at >= @resync_gap do
      sources =
        :lists.map(
          fn
            %{kind: :external} = source -> Source.hurry(source, state.mono)
            source -> source
          end,
          state.sources
        )

      {:ok, %{state | sources: sources, resync_at: state.mono}}
    else
      {:ok, state}
    end
  end

  def handle_key({:char, char}, state) when char == ?p or char == ?P do
    {:ok, %{state | discipline: Discipline.toggle_panic(state.discipline)}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def leave(state) do
    :lists.foreach(
      fn
        %{busy: {pid, _ref}} -> Process.exit(pid, :kill)
        _idle -> :ok
      end,
      state.sources
    )
  end

  defp configure(%{ready: true} = state), do: state

  defp configure(state) do
    node =
      case :erlang.node() do
        :nonode@nohost -> "local"
        name -> :erlang.atom_to_binary(name, :latin1)
      end

    %{
      state
      | sources: Ntp.sources(Nvs.get(:ntp_hosts)),
        discipline: Discipline.new(Discipline.threshold(Nvs.get(:ntp_panic))),
        node: node,
        ready: true
    }
  end

  defp check_wifi(%{wifi_at: at} = state, mono) when at != nil and mono - at < @wifi_every,
    do: state

  defp check_wifi(%{local: %{}} = state, mono), do: %{state | wifi_at: mono}

  defp check_wifi(state, mono) do
    local = if Wifi.status().synced, do: :known, else: :unknown

    %{state | local: local, wifi_at: mono}
  end

  defp ask(state, mono) do
    sources =
      :lists.map(
        fn source ->
          if Source.due?(source, mono),
            do: Source.asked(source, Ntp.ask(source.host, self()), mono),
            else: source
        end,
        state.sources
      )

    %{state | sources: sources}
  end

  defp discipline(%{disciplined_at: at} = state, mono)
       when at != nil and mono - at < @discipline_every,
       do: state

  defp discipline(state, mono) do
    selection = Select.select(entries(state))
    {action, next} = Discipline.decide(state.discipline, selection, state.local != :unknown, mono)

    act(action, %{state | discipline: next, disciplined_at: mono}, selection, mono)
  end

  defp act({:step, offset}, state, selection, _mono) do
    set_clock(offset)
    :io.format(~c"Ntp: stepped ~p us~n", [offset])
    Wifi.clock_set()
    leave(state)

    now = :erlang.system_time(:microsecond)
    error = div(selection.result.to - selection.result.from, 2)

    %{
      state
      | sources: :lists.map(&Source.flush/1, state.sources),
        local: %{at: now, error: error},
        now: now,
        note: nil
    }
  end

  defp act({:slew, micros}, state, _selection, _mono) do
    set_clock(micros)

    %{
      state
      | sources: :lists.map(&Source.shift_samples(&1, micros), state.sources),
        now: :erlang.system_time(:microsecond),
        note: nil
    }
  end

  defp act(:spike, state, _selection, mono) do
    sources =
      :lists.map(
        fn
          %{kind: :external} = source -> Source.hurry(source, mono)
          source -> source
        end,
        state.sources
      )

    %{state | sources: sources, note: :spike}
  end

  defp act(:wait, state, _selection, _mono), do: %{state | note: :spike}

  defp act(:panic, %{note: :panic} = state, _selection, _mono), do: state

  defp act(:panic, state, selection, _mono) do
    :io.format(~c"Ntp: refusing a step of ~p us~n", [
      div(selection.result.from + selection.result.to, 2)
    ])

    %{state | note: :panic}
  end

  defp act(:none, state, _selection, _mono), do: %{state | note: nil}

  defp set_clock(micros) do
    target = :erlang.system_time(:microsecond) + micros

    :atomvm.posix_clock_settime(
      :realtime,
      {div(target, 1_000_000), rem(target, 1_000_000) * 1_000}
    )
  end

  defp entries(state) do
    :lists.foldr(
      fn source, acc ->
        case Source.best(source, state.now) do
          nil -> acc
          best -> [:maps.put(:id, source.host, best) | acc]
        end
      end,
      [],
      state.sources
    )
  end

  @impl true
  def render(state) do
    entries = entries(state)
    selection = Select.select(entries)
    centre = centre(selection)
    rows = rows(state, entries, selection)
    placed = Scale.place(endpoints(rows, selection, centre))

    {items, _y} =
      :lists.foldl(
        fn row, {items, y} ->
          {items ++ row_items(row, selection, centre, placed, y), y + @pitch}
        end,
        {[], @top},
        rows
      )

    items ++
      output(state, selection, centre, placed) ++
      axis() ++
      Nav.hint([{"R", "resync"}, {"P", panic(state.discipline)}], @help_y, Theme.dim()) ++
      centre_line()
  end

  defp centre(%{result: %{from: from, to: to}}), do: div(from + to, 2)
  defp centre(_unsynced), do: 0

  defp rows(state, entries, selection) do
    local = %{
      label: state.node,
      kind: :local,
      tally: " ",
      interval: local_interval(state),
      note: "unknown"
    }

    sources =
      :lists.map(
        fn source ->
          %{
            label: Source.label(source),
            kind: source.kind,
            tally: tally(source, selection),
            interval: interval(source.host, entries),
            note: note(source)
          }
        end,
        state.sources
      )

    all = [local | sources]
    unknown = :lists.filter(&(&1.interval == :unknown), all)
    timed = :lists.filter(&is_map(&1.interval), all)
    waiting = :lists.filter(&(&1.interval == nil), all)

    unknown ++ :lists.sort(&before?/2, timed) ++ waiting
  end

  defp local_interval(%{local: :unknown}), do: :unknown
  defp local_interval(%{local: :known}), do: %{from: 0, to: 1}

  defp local_interval(%{local: %{at: at, error: error}, now: now}) do
    grown = error + div(max(now - at, 0) * @phi_ppm, 1_000_000)
    %{from: -grown, to: grown + 1}
  end

  defp before?(a, b), do: {a.interval.from, a.interval.to} <= {b.interval.from, b.interval.to}

  defp interval(host, entries) do
    case :lists.filter(&(&1.id == host), entries) do
      [entry] -> %{from: entry.from, to: entry.to, id: host}
      [] -> nil
    end
  end

  defp tally(source, selection) do
    cond do
      Source.status(source) == :unreachable -> "?"
      selection.peer != nil and selection.peer.id == source.host -> "*"
      :lists.member(source.host, selection.chimers) -> "+"
      :lists.member(source.host, selection.tickers) -> "x"
      true -> " "
    end
  end

  defp note(source) do
    case Source.status(source) do
      :pending -> "asking..."
      _other -> describe(source.last)
    end
  end

  defp endpoints(rows, selection, centre) do
    timed = :lists.filter(&is_map(&1.interval), rows)
    values = :lists.flatmap(&[&1.interval.from - centre, &1.interval.to - centre], timed)

    case selection.result do
      nil -> [0 | values]
      result -> [result.from - centre, result.to - centre | values]
    end
  end

  defp row_items(row, selection, centre, placed, y) do
    right = bounds_text(row, centre)
    room = @columns - 5 - byte_size(right)

    [
      {:text, 8, y, :default16px, tally_colour(row.tally), Theme.bg(), row.tally},
      {:text, 8 + 2 * @char_w, y, :default16px, Theme.fg(), Theme.bg(), letter(row, selection)},
      {:text, 8 + 4 * @char_w, y, :default16px, label_colour(row), Theme.bg(),
       clip(row.label, room)},
      {:text, Readout.right_x(right), y, :default16px, Theme.dim(), Theme.bg(), right}
    ] ++ bar(row, centre, placed, y + @bar_dy)
  end

  defp bounds_text(%{interval: %{from: from, to: to}}, centre) when to - from == 1,
    do: point(from - centre)

  defp bounds_text(%{interval: %{from: from, to: to}}, centre),
    do: span(from - centre, to - centre)

  defp bounds_text(row, _centre), do: row.note

  defp letter(%{interval: :unknown}, _selection), do: "?"

  defp letter(%{interval: %{} = interval}, %{result: %{} = result}),
    do: Allen.symbol(Allen.relation(interval, result))

  defp letter(_row, _selection), do: " "

  defp bar(%{interval: :unknown}, _centre, _placed, y) do
    {left, right} = Scale.bounds()
    [{:rect, left, y, right - left, @bar_h, Theme.dim()}]
  end

  defp bar(%{interval: %{from: from, to: to}} = row, centre, placed, y) do
    x = :maps.get(from - centre, placed)
    w = max(:maps.get(to - centre, placed) - x, 1)

    if row.tally == "x",
      do: hollow(x, y, w, Theme.alert()),
      else: [{:rect, x, y, w, @bar_h, kind_colour(row.kind)}]
  end

  defp bar(_row, _centre, _placed, _y), do: []

  defp hollow(x, y, w, colour) when w < 3, do: [{:rect, x, y, w, @bar_h, colour}]

  defp hollow(x, y, w, colour) do
    [
      {:rect, x, y, w, 1, colour},
      {:rect, x, y + @bar_h - 1, w, 1, colour},
      {:rect, x, y, 1, @bar_h, colour},
      {:rect, x + w - 1, y, 1, @bar_h, colour}
    ]
  end

  defp output(state, selection, centre, placed) do
    time = stamp(state.now + centre)
    colour = level_colour(selection)

    bounds =
      case selection.result do
        nil -> ""
        result -> span(result.from - centre, result.to - centre)
      end

    bar =
      case selection.result do
        nil ->
          [{:rect, Scale.centre(), @out_bar_y, 1, @bar_h, colour}]

        result ->
          x = :maps.get(result.from - centre, placed)
          w = max(:maps.get(result.to - centre, placed) - x, 1)
          [{:rect, x, @out_bar_y, w, @bar_h, colour}]
      end

    [
      {:text, 8, @out_y, :default16px, Theme.fg(), Theme.bg(), time},
      {:text, Readout.right_x(bounds), @out_y, :default16px, Theme.dim(), Theme.bg(), bounds},
      {:text, 8, @verdict_y, :default16px, colour, Theme.bg(),
       Text.cp437(verdict(selection, length(state.sources)) <> remark(state.note))}
    ] ++ bar
  end

  defp axis do
    {left, right} = Scale.bounds()

    ticks =
      :lists.flatmap(
        fn {label, micros} ->
          :lists.flatmap(
            fn x ->
              [
                {:rect, x, @axis_y - 2, 1, 5, Theme.dim()},
                {:text, x - div(byte_size(label) * @char_w, 2), @axis_y + 3, :default16px,
                 Theme.dim(), Theme.bg(), label}
              ]
            end,
            [Scale.x(-micros), Scale.x(micros)]
          )
        end,
        Scale.ticks()
      )

    ticks ++ [{:rect, left, @axis_y, right - left, 1, Theme.dim()}]
  end

  defp centre_line do
    x = Scale.centre()

    :lists.map(
      fn y -> {:rect, x, y, 1, 2, Theme.dim()} end,
      :lists.seq(@top, @out_bar_y + @bar_h, 4)
    )
  end

  @doc """
  The conviction in a selection, given how many sources are configured.

      iex> selection = Badge.Ntp.Select.select([%{id: :a, from: -900, to: 901, stratum: 1}])
      iex> Badge.Page.Ntp.verdict(selection, 4)
      "synced 1/1 of 4 st2 ±0.90ms"
  """
  @spec verdict(Select.selection(), non_neg_integer) :: binary
  def verdict(selection, configured) do
    counts =
      :erlang.integer_to_binary(selection.size) <>
        "/" <>
        :erlang.integer_to_binary(selection.count) <>
        if(selection.count < configured,
          do: " of " <> :erlang.integer_to_binary(configured),
          else: ""
        )

    case selection do
      %{status: :synced, result: result, peer: peer} ->
        stratum = :erlang.integer_to_binary(:maps.get(:stratum, peer, 15) + 1)
        "synced " <> counts <> " st" <> stratum <> " ±" <> amount(div(result.to - result.from, 2))

      %{reason: :contested} ->
        "unsynced " <> counts <> " contested"

      _unsynced ->
        "unsynced " <> counts
    end
  end

  @doc """
  Two offsets in microseconds, in the unit of the larger.

      iex> Badge.Page.Ntp.span(-1_234, 2_345)
      "-1.23 +2.35ms"
      iex> Badge.Page.Ntp.span(-56 * 31_557_600_000_000, -56 * 31_557_600_000_000 + 9)
      "-56.00 -56.00y"
  """
  @spec span(integer, integer) :: binary
  def span(from, to) do
    {divisor, unit} = unit(max(abs(from), abs(to)))

    signed(from, divisor) <> " " <> signed(to, divisor) <> unit
  end

  @doc "One offset in microseconds, in its own unit."
  @spec point(integer) :: binary
  def point(micros) do
    {divisor, unit} = unit(abs(micros))

    signed(micros, divisor) <> unit
  end

  @doc "A magnitude in microseconds, in its own unit."
  @spec amount(non_neg_integer) :: binary
  def amount(micros) do
    {divisor, unit} = unit(micros)

    fixed(micros, divisor) <> unit
  end

  defp unit(micros) when micros < 1_000_000, do: {1_000, "ms"}
  defp unit(micros) when micros < 60_000_000, do: {1_000_000, "s"}
  defp unit(micros) when micros < 3_600_000_000, do: {60_000_000, "m"}
  defp unit(micros) when micros < 86_400_000_000, do: {3_600_000_000, "h"}
  defp unit(micros) when micros < 31_557_600_000_000, do: {86_400_000_000, "d"}
  defp unit(_micros), do: {31_557_600_000_000, "y"}

  defp signed(micros, divisor) when micros < 0, do: "-" <> fixed(-micros, divisor)
  defp signed(micros, divisor), do: "+" <> fixed(micros, divisor)

  defp fixed(micros, divisor) do
    hundredths = div(micros * 100 + div(divisor, 2), divisor)
    part = rem(hundredths, 100)
    pad = if part < 10, do: "0", else: ""

    :erlang.integer_to_binary(div(hundredths, 100)) <>
      "." <> pad <> :erlang.integer_to_binary(part)
  end

  @doc "System time in microseconds as `HH:MM:SS.mmmZ`."
  @spec stamp(integer) :: binary
  def stamp(micros) do
    millis = rem(div(micros, 1_000), 1_000)

    pad =
      cond do
        millis < 10 -> "00"
        millis < 100 -> "0"
        true -> ""
      end

    Clock.format(div(micros, 1_000_000)) <> "." <> pad <> :erlang.integer_to_binary(millis) <> "Z"
  end

  defp remark(:spike), do: " spike"
  defp remark(:panic), do: " panic"
  defp remark(nil), do: ""

  defp panic(%{panic: true}), do: "panic on"
  defp panic(_off), do: "panic off"

  defp clip(text, room) when byte_size(text) <= room, do: text
  defp clip(text, room), do: :binary.part(text, 0, max(room, 0))

  defp kind_colour(:external), do: Theme.muted()
  defp kind_colour(_internal), do: Theme.select()

  defp label_colour(%{tally: "x"}), do: Theme.alert()
  defp label_colour(%{tally: "?"}), do: Theme.dim()
  defp label_colour(_row), do: Theme.fg()

  defp tally_colour("x"), do: Theme.alert()
  defp tally_colour("*"), do: Theme.ok()
  defp tally_colour(_tally), do: Theme.fg()

  defp level_colour(%{status: :synced, size: size, count: count})
       when count >= 3 and size == count,
       do: Theme.ok()

  defp level_colour(%{status: :synced, count: count}) when count >= 3, do: Theme.accent()
  defp level_colour(%{status: :synced}), do: Theme.warn()
  defp level_colour(_unsynced), do: Theme.alert()

  defp describe(nil), do: ""
  defp describe(:ok), do: ""

  defp describe({:error, reason}) when is_atom(reason),
    do: :erlang.atom_to_binary(reason, :latin1)

  defp describe({:error, {tag, _detail}}) when is_atom(tag),
    do: :erlang.atom_to_binary(tag, :latin1)

  defp describe(_error), do: "error"
end
