defmodule Badge.Allen.Network do
  @moduledoc """
  A qualitative constraint network over Allen relations, propagated by path
  consistency, following Tempo's `Tempo.Interval.RelationNetwork`.

  Each pair of labels carries the set of relations still possible between
  them. `constrain/4` narrows a pair; `propagate/1` narrows every other pair
  that follows. Pruning is sound but incomplete: `{:ok, network}` means no
  contradiction was found, while `{:error, {:inconsistent, pair}}` is
  definitive.

      iex> alias Badge.Allen.Network
      iex> net =
      ...>   Network.new([:fire, :rebuild, :occupation])
      ...>   |> Network.constrain(:fire, [:precedes], :rebuild)
      ...>   |> Network.constrain(:rebuild, [:during], :occupation)
      iex> {:ok, net} = Network.propagate(net)
      iex> Network.between(net, :fire, :occupation)
      [:precedes, :meets, :overlaps, :starts, :during]

  A network is a plain map; sets are held as masks (see `Badge.Allen`).
  """

  import Bitwise

  alias Badge.Allen

  @type label :: term
  @type t :: %{labels: [label], edges: %{{label, label} => non_neg_integer}}

  @doc "A network over `labels` with nothing asserted: every pair holds all 13 relations."
  @spec new([label]) :: t
  def new(labels) do
    unique = unique(labels, [])
    full = Allen.full_mask()

    edges =
      :lists.foldl(
        fn a, acc ->
          :lists.foldl(
            fn
              ^a, inner -> inner
              b, inner -> :maps.put({a, b}, full, inner)
            end,
            acc,
            unique
          )
        end,
        %{},
        unique
      )

    %{labels: unique, edges: edges}
  end

  @doc "The relations still possible from `a` to `b`, `[:equals]` for a label with itself."
  @spec between(t, label, label) :: [Allen.relation()] | {:error, {:unknown_label, label}}
  def between(network, a, b) do
    with :ok <- known(network, a), :ok <- known(network, b) do
      Allen.from_mask(mask(network, a, b))
    end
  end

  @doc """
  Narrows what is possible from `a` to `b` to `relations`, recording the
  converse on `b` to `a`. Call `propagate/1` to draw out what follows.
  """
  @spec constrain(t, label, [Allen.relation()], label) ::
          t | {:error, {:unknown_label, label} | {:invalid_relation, term}}
  def constrain(network, a, relations, b) do
    with :ok <- known(network, a),
         :ok <- known(network, b),
         narrowing when is_integer(narrowing) <- Allen.to_mask(relations) do
      put_edge(network, a, b, mask(network, a, b) &&& narrowing)
    end
  end

  @doc """
  Propagates every constraint to a fixpoint:
  `R(i,k) <- R(i,k) & (R(i,j) . R(j,k))` until nothing changes.
  """
  @spec propagate(t) :: {:ok, t} | {:error, {:inconsistent, {label, label}}}
  def propagate(network) do
    pairs = :maps.to_list(network.edges)

    case :lists.keyfind(0, 2, pairs) do
      {pair, 0} -> {:error, {:inconsistent, pair}}
      false -> run(network, :maps.keys(network.edges))
    end
  end

  @doc "Whether `propagate/1` finds no contradiction; `true` is not proof of satisfiability."
  @spec consistent?(t) :: boolean
  def consistent?(network) do
    case propagate(network) do
      {:ok, _network} -> true
      {:error, _reason} -> false
    end
  end

  defp run(network, []), do: {:ok, network}

  defp run(network, [{i, j} | queue]) do
    case revise_through(network.labels, network, i, j, queue) do
      {:ok, network, queue} -> run(network, queue)
      {:error, _reason} = error -> error
    end
  end

  defp revise_through([], network, _i, _j, queue), do: {:ok, network, queue}

  defp revise_through([k | rest], network, i, j, queue) when k == i or k == j,
    do: revise_through(rest, network, i, j, queue)

  defp revise_through([k | rest], network, i, j, queue) do
    with {:ok, network, queue} <- revise(network, i, k, leg(network, i, j, k), queue),
         {:ok, network, queue} <- revise(network, k, j, leg(network, k, i, j), queue) do
      revise_through(rest, network, i, j, queue)
    end
  end

  defp leg(network, from, via, to),
    do: Allen.compose_mask(mask(network, from, via), mask(network, via, to))

  defp revise(network, a, b, implied, queue) do
    current = mask(network, a, b)
    narrowed = current &&& implied

    cond do
      narrowed == current -> {:ok, network, queue}
      narrowed == 0 -> {:error, {:inconsistent, {a, b}}}
      true -> {:ok, put_edge(network, a, b, narrowed), [{a, b} | queue]}
    end
  end

  # The converse is stored too, so the two directions never disagree.
  defp put_edge(network, a, b, mask) do
    edges = :maps.put({b, a}, Allen.converse_mask(mask), :maps.put({a, b}, mask, network.edges))

    %{network | edges: edges}
  end

  defp mask(_network, a, a), do: Allen.to_mask([:equals])
  defp mask(network, a, b), do: :maps.get({a, b}, network.edges)

  defp known(network, label) do
    if :lists.member(label, network.labels), do: :ok, else: {:error, {:unknown_label, label}}
  end

  defp unique([], acc), do: :lists.reverse(acc)

  defp unique([label | rest], acc) do
    if :lists.member(label, acc), do: unique(rest, acc), else: unique(rest, [label | acc])
  end
end
