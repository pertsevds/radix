alias Radix

# Fastest way to get (exactly) a key,value-pair from a radix tree
# - tree is densly populated
# - all bits of the key need to be checked

# % mix run benchmarks/radix_get.exs
#

# IPv4 style keys (32 bits)
# ------------------------------------------------------------------------------
# Name               ips        average  deviation         median         99th %
# alt4_get        2.49 M      401.89 ns  ±1718.19%         372 ns         726 ns
# rdx_get         1.28 M      780.05 ns  ±7618.97%         578 ns        1238 ns
# alt0_get        1.26 M      796.32 ns  ±7394.15%         580 ns        1563 ns
# alt1_get        1.06 M      943.18 ns  ±6013.52%         757 ns        1823 ns
# alt3_get        0.83 M     1208.43 ns  ±2640.45%        1090 ns        2066 ns
# alt2_get        0.70 M     1436.82 ns  ±2460.20%        1284 ns        2092 ns

# Comparison: 
# alt4_get        2.49 M
# rdx_get         1.28 M - 1.94x slower +378.16 ns
# alt0_get        1.26 M - 1.98x slower +394.43 ns
# alt1_get        1.06 M - 2.35x slower +541.30 ns
# alt3_get        0.83 M - 3.01x slower +806.55 ns
# alt2_get        0.70 M - 3.58x slower +1034.94 ns
# ------------------------------------------------------------------------------

# IPv6 style keys (128 bits)
# ------------------------------------------------------------------------------
# Name               ips        average  deviation         median         99th %
# alt0_get        1.23 M        0.81 μs  ±4756.09%        0.68 μs        1.39 μs
# rdx_get         1.21 M        0.83 μs  ±6366.42%        0.66 μs        1.63 μs
# alt1_get        1.04 M        0.96 μs  ±3957.69%        0.82 μs        1.62 μs
# alt3_get        0.63 M        1.58 μs  ±2920.43%        1.21 μs        3.25 μs
# alt4_get        0.40 M        2.47 μs  ±1477.23%        2.19 μs        4.69 μs
# alt2_get        0.23 M        4.43 μs   ±319.15%        4.20 μs        5.55 μs

# Comparison: 
# alt0_get        1.23 M
# rdx_get         1.21 M - 1.02x slower +0.0130 μs
# alt1_get        1.04 M - 1.19x slower +0.152 μs
# alt3_get        0.63 M - 1.94x slower +0.76 μs
# alt4_get        0.40 M - 3.05x slower +1.66 μs
# alt2_get        0.23 M - 5.45x slower +3.61 μs
# ------------------------------------------------------------------------------

defmodule Alt0 do
  # bitstring decode inlined in leaf fun

  # root/internal node is {b,l,r}
  # leaf is nil or [{k,v}, _]
  def leaf({bit, l, r}, key, max) when bit < max do
    <<_::size(bit), bit::1, _::bitstring>> = key

    case(bit) do
      0 -> leaf(l, key, max)
      1 -> leaf(r, key, max)
    end
  end

  def leaf({_, l, _}, key, max),
    do: leaf(l, key, max)

  def leaf(leaf, _key, _max), do: leaf

  def get({0, _, _} = tree, key, default \\ nil) do
    # leaf -> :lists.keyfind(key, 1, leaf) || default
    kmax = :erlang.bit_size(key)

    case leaf(tree, key, kmax) do
      nil -> default
      leaf -> leaf_get(leaf, key, kmax) || default
    end
  end

  defp leaf_get([], _key, _kmax), do: false

  defp leaf_get([{k, v} | _tail], key, _kmax) when k == key,
    do: {k, v}

  defp leaf_get([{k, _v} | _tail], _key, kmax) when bit_size(k) < kmax,
    do: false

  defp leaf_get([{_k, _v} | tail], key, kmax),
    do: leaf_get(tail, key, kmax)
end

defmodule Alt1 do
  # bitstring decode w/ precalculated bit_size(key)
  def bit(key, pos, max) when pos < max do
    <<_::size(pos), bit::1, _::bitstring>> = key
    bit
  end

  def bit(_key, _pos, _max),
    do: 0

  # root/internal node is {b,l,r}
  # leaf is nil or [{k,v}, _]
  def leaf({bit, l, r}, key, max) do
    case(bit(key, bit, max)) do
      0 -> leaf(l, key, max)
      1 -> leaf(r, key, max)
    end
  end

  def leaf(leaf, _key, _max), do: leaf

  def get({0, _, _} = tree, key, default \\ nil) do
    case leaf(tree, key, :erlang.bit_size(key)) do
      nil -> default
      leaf -> :lists.keyfind(key, 1, leaf) || default
    end
  end
end

defmodule Alt2 do
  # key converted to tuple of 1's and 0's at the start, elem access to bits
  def get({0, _, _} = tree, key, default \\ nil) do
    k = for <<x::1 <- key>>, do: x
    k = List.to_tuple(k)

    case getp(tree, k, tuple_size(k)) do
      nil -> default
      leaf -> :lists.keyfind(key, 1, leaf)
    end
  end

  def getp({b, l, r}, key, max) when b < max do
    case elem(key, b) do
      0 -> getp(l, key, max)
      1 -> getp(r, key, max)
    end
  end

  def getp({_b, l, _}, key, max),
    do: getp(l, key, max)

  def getp(leaf, _key, _max), do: leaf
end

defmodule Alt3 do
  # create key as tuple of ints

  @mask {0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01}
  def make_key(k) do
    key =
      case 8 - rem(bit_size(k), 8) do
        0 -> k
        n -> <<k::bits, 0::size(n)>>
      end

    :erlang.bitstring_to_list(key) |> List.to_tuple()
  end

  # root/internal node is {b,l,r}
  # leaf is nil or [{k,v}, _]
  def leaf({bit, l, r}, key) do
    byte = div(bit, 8)
    mask = rem(bit, 8)

    case(:erlang.band(elem(key, byte), elem(@mask, mask))) do
      0 -> leaf(l, key)
      _ -> leaf(r, key)
    end
  end

  def leaf(leaf, _key), do: leaf

  def get({0, _, _} = tree, key, default \\ nil) do
    case leaf(tree, make_key(key)) do
      nil -> default
      leaf -> :lists.keyfind(key, 1, leaf) || default
    end
  end
end

defmodule Alt4 do
  # create key as integer

  @compile {:inline, bit: 3}
  defp bit(key, pos, max) do
    if pos < max,
      do: :erlang.bsl(1, max - pos - 1) |> :erlang.band(key),
      else: 0
  end

  # root/internal node is {b,l,r}
  # leaf is nil or [{k,v}, _]
  def leaf({bit, l, r}, key, max) do
    # check value at position `bit`
    if bit(key, bit, max) == 0,
      do: leaf(l, key, max),
      else: leaf(r, key, max)
  end

  def leaf(leaf, _key, _max), do: leaf

  def get({0, _, _} = tree, key, default \\ nil) do
    # convert key to integer, pads with 0-bits to multiple of 8
    max = :erlang.bit_size(key)

    key_int =
      case 8 - rem(max, 8) do
        8 -> key
        n -> <<key::bits, 0::size(n)>>
      end
      |> :binary.decode_unsigned()

    case leaf(tree, key_int, max) do
      nil -> default
      leaf -> :lists.keyfind(key, 1, leaf) || default
    end
  end
end

keyvalues = for x <- 0..255, y <- 0..255, do: {<<x, y, x, y>>, <<x, y>>}

rdx = Radix.new(keyvalues)
key = Enum.shuffle(keyvalues) |> List.first() |> elem(0)

IO.inspect(Alt0.get(rdx, key), label: :alt0_get)
IO.inspect(Alt1.get(rdx, key), label: :alt1_get)
IO.inspect(Alt2.get(rdx, key), label: :alt2_get)
IO.inspect(Alt3.get(rdx, key), label: :alt3_get)
IO.inspect(Alt4.get(rdx, key), label: :alt4_get)
IO.inspect(Radix.get(rdx, key), label: :radix_get)

Benchee.run(%{
  "rdx_get" => fn -> Radix.get(rdx, key) end,
  "alt0_get" => fn -> Alt0.get(rdx, key) end,
  "alt1_get" => fn -> Alt1.get(rdx, key) end,
  "alt2_get" => fn -> Alt2.get(rdx, key) end,
  "alt3_get" => fn -> Alt3.get(rdx, key) end,
  "alt4_get" => fn -> Alt4.get(rdx, key) end
})
