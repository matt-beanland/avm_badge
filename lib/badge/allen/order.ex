defmodule Badge.Allen.Order do
  @moduledoc """
  Allen's 13 relations, in canonical order, and the endpoint test that picks
  one for two half-open `[from, to)` intervals given as numbers.
  """

  @relations [
    :precedes,
    :meets,
    :overlaps,
    :finished_by,
    :contains,
    :starts,
    :equals,
    :started_by,
    :during,
    :finishes,
    :overlapped_by,
    :met_by,
    :preceded_by
  ]

  @doc "The 13 relations in Allen's canonical order."
  @spec relations() :: [atom]
  def relations, do: @relations

  @doc "The relation from `[a1, a2)` to `[b1, b2)`; both must be non-empty."
  @spec classify(number, number, number, number) :: atom
  def classify(a1, a2, b1, b2) do
    cond do
      a2 < b1 -> :precedes
      a2 == b1 -> :meets
      b2 < a1 -> :preceded_by
      b2 == a1 -> :met_by
      a1 == b1 -> same_start(a2, b2)
      a2 == b2 -> same_end(a1, b1)
      a1 < b1 -> if a2 < b2, do: :overlaps, else: :contains
      true -> if a2 < b2, do: :during, else: :overlapped_by
    end
  end

  defp same_start(a2, b2) when a2 < b2, do: :starts
  defp same_start(a2, b2) when a2 > b2, do: :started_by
  defp same_start(_a2, _b2), do: :equals

  defp same_end(a1, b1) when a1 > b1, do: :finishes
  defp same_end(_a1, _b1), do: :finished_by
end
