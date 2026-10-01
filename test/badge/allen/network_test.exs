defmodule Badge.Allen.NetworkTest do
  use ExUnit.Case, async: true

  alias Badge.Allen.Network

  doctest Badge.Allen.Network

  test "a new network knows nothing, except that a label equals itself" do
    net = Network.new([:a, :b, :a])

    assert net.labels == [:a, :b]
    assert length(Network.between(net, :a, :b)) == 13
    assert Network.between(net, :a, :a) == [:equals]
  end

  test "constrain records the converse and narrows rather than replaces" do
    net = Network.new([:a, :b]) |> Network.constrain(:a, [:precedes, :meets], :b)
    assert Network.between(net, :b, :a) == [:met_by, :preceded_by]

    net = Network.constrain(net, :a, [:meets, :overlaps], :b)
    assert Network.between(net, :a, :b) == [:meets]
  end

  test "propagation chains precedes" do
    {:ok, net} =
      Network.new([:a, :b, :c])
      |> Network.constrain(:a, [:precedes], :b)
      |> Network.constrain(:b, [:precedes], :c)
      |> Network.propagate()

    assert Network.between(net, :a, :c) == [:precedes]
    assert Network.between(net, :c, :a) == [:preceded_by]
  end

  test "an impossible cycle is reported" do
    net =
      Network.new([:a, :b, :c])
      |> Network.constrain(:a, [:precedes], :b)
      |> Network.constrain(:b, [:precedes], :c)
      |> Network.constrain(:c, [:precedes], :a)

    assert {:error, {:inconsistent, _pair}} = Network.propagate(net)
    refute Network.consistent?(net)
  end

  test "a contradiction asserted directly is reported" do
    net =
      Network.new([:a, :b])
      |> Network.constrain(:a, [:precedes], :b)
      |> Network.constrain(:a, [:preceded_by], :b)

    assert Network.propagate(net) == {:error, {:inconsistent, {:a, :b}}}
  end

  test "a consistent network stays consistent" do
    assert Network.new([:a, :b]) |> Network.constrain(:a, [:precedes], :b) |> Network.consistent?()
  end

  test "bad input is an error, not a crash" do
    net = Network.new([:a, :b])

    assert Network.between(net, :a, :zzz) == {:error, {:unknown_label, :zzz}}
    assert Network.constrain(net, :zzz, [:meets], :a) == {:error, {:unknown_label, :zzz}}
    assert Network.constrain(net, :a, [:nope], :b) == {:error, {:invalid_relation, :nope}}
  end
end
