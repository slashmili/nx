defmodule Torchx.BackendTest do
  use Torchx.Case, async: true

  alias Torchx.Backend, as: TB
  doctest TB

  @types [{:s, 8}, {:u, 8}, {:s, 16}, {:s, 32}, {:s, 64}, {:bf, 16}, {:f, 32}, {:f, 64}]
  @bf16_and_ints [{:s, 8}, {:u, 8}, {:s, 16}, {:s, 32}, {:s, 64}, {:bf, 16}]
  @ints [{:s, 8}, {:u, 8}, {:s, 16}, {:s, 32}, {:s, 64}]
  @ops [:add, :subtract, :divide, :remainder, :multiply, :power, :atan2, :min, :max]
  @ops_unimplemented_for_bfloat [:remainder, :atan2, :power]
  @ops_with_bfloat_specific_result [:divide]
  @bitwise_ops [:bitwise_and, :bitwise_or, :bitwise_xor, :left_shift, :right_shift]
  @logical_ops [
    :equal,
    :not_equal,
    :greater,
    :less,
    :greater_equal,
    :less_equal,
    :logical_and,
    :logical_or,
    :logical_xor
  ]
  @unary_ops [:abs, :bitwise_not, :ceil, :floor, :negate, :round, :sign]

  defp test_binary_op(op, data_a \\ [[5, 6], [7, 8]], data_b \\ [[1, 2], [3, 4]], type_a, type_b) do
    a = Nx.tensor(data_a, type: type_a)
    b = Nx.tensor(data_b, type: type_b)
    c = Kernel.apply(Nx, op, [a, b])

    binary_a = Nx.backend_transfer(a, Nx.BinaryBackend)
    binary_b = Nx.backend_transfer(b, Nx.BinaryBackend)
    binary_c = Kernel.apply(Nx, op, [binary_a, binary_b])
    assert Nx.backend_transfer(c) == binary_c

    mixed_c = Kernel.apply(Nx, op, [a, binary_b])
    assert Nx.backend_transfer(mixed_c) == binary_c
  end

  defp test_unary_op(op, data \\ [[1, 2], [3, 4]], type) do
    t = Nx.tensor(data, type: type)
    r = Kernel.apply(Nx, op, [t])

    binary_t = Nx.backend_transfer(t, Nx.BinaryBackend)
    binary_r = Kernel.apply(Nx, op, [binary_t])
    assert Nx.backend_transfer(r) == binary_r
  end

  describe "binary ops" do
    for op <- @ops ++ @logical_ops,
        type_a <- @types,
        type_b <- @types,
        not (op in (@ops_unimplemented_for_bfloat ++ @ops_with_bfloat_specific_result) and
               Nx.Type.merge(type_a, type_b) == {:bf, 16}) do
      test "#{op}(#{Nx.Type.to_string(type_a)}, #{Nx.Type.to_string(type_b)})" do
        op = unquote(op)
        type_a = unquote(type_a)
        type_b = unquote(type_b)

        test_binary_op(op, type_a, type_b)
      end
    end
  end

  # quotient/2 works only with integers, so we put it here.
  describe "binary bitwise ops" do
    for op <- @bitwise_ops ++ [:quotient],
        type_a <- @ints,
        type_b <- @ints do
      test "#{op}(#{Nx.Type.to_string(type_a)}, #{Nx.Type.to_string(type_b)})" do
        op = unquote(op)
        type_a = unquote(type_a)
        type_b = unquote(type_b)

        test_binary_op(op, type_a, type_b)
      end
    end
  end

  describe "unary ops" do
    for op <- @unary_ops -- [:bitwise_not],
        type <- @types do
      test "#{op}(#{Nx.Type.to_string(type)})" do
        test_unary_op(unquote(op), unquote(type))
      end
    end

    for type <- @ints do
      test "bitwise_not(#{Nx.Type.to_string(type)})" do
        test_unary_op(:bitwise_not, unquote(type))
      end
    end

    test "all? fails with more than one axis passed" do
      assert_raise ArgumentError, ":axes option only accepts a single axis per call", fn ->
        t = Nx.tensor([[[1]]])
        Torchx.Backend.all?(t, t, axes: [0, 1])
      end
    end
  end

  # Division and power with bfloat16 are special cases in PyTorch,
  # because it upcasts bfloat16 args to float for numerical accuracy purposes.
  # So, e.g., the result of division is different from what direct bf16 by bf16 division gives us.
  # I.e. 1/5 == 0.19921875 in direct bf16 division and 0.2001953125 when dividing floats
  # converting them to bf16 afterwards (PyTorch style).
  describe "bfloat16" do
    for type_a <- @bf16_and_ints,
        type_b <- @bf16_and_ints,
        type_a == {:bf, 16} or type_b == {:bf, 16} do
      test "divide(#{Nx.Type.to_string(type_a)}, #{Nx.Type.to_string(type_b)})" do
        type_a = unquote(type_a)
        type_b = unquote(type_b)

        a = Nx.tensor([[1, 2], [3, 4]], type: type_a)
        b = Nx.tensor([[5, 6], [7, 8]], type: type_b)

        c = Nx.divide(a, b)

        assert Nx.backend_transfer(c) ==
                 Nx.tensor([[0.2001953125, 0.333984375], [0.427734375, 0.5]],
                   type: {:bf, 16},
                   backend: Nx.BinaryBackend
                 )
      end
    end
  end

  describe "vectors" do
    for type_a <- @types,
        type_b <- @types do
      test "outer(#{Nx.Type.to_string(type_a)}, #{Nx.Type.to_string(type_b)})" do
        type_a = unquote(type_a)
        type_b = unquote(type_b)

        test_binary_op(:outer, [1, 2, 3, 4], [5, 6, 7, 8], type_a, type_b)
      end
    end
  end

  describe "aggregates" do
    test "sum throws on type mismatch" do
      t = Nx.tensor([[101, 102], [103, 104]], type: {:u, 8})

      assert_raise(
        ArgumentError,
        "Torchx does not support unsigned 64 bit integer (explicitly cast the input tensor to a signed integer before taking sum)",
        fn -> Nx.sum(t) end
      )
    end
  end

  describe "creation" do
    test "eye" do
      t = Nx.eye({9, 9}) |> Nx.backend_transfer()
      one = Nx.tensor(1, backend: Nx.BinaryBackend)
      zero = Nx.tensor(0, backend: Nx.BinaryBackend)

      for i <- 0..8, j <- 0..8 do
        assert (i == j and t[i][j] == one) or t[i][j] == zero
      end
    end

    test "iota" do
      t = Nx.iota({2, 3})
      assert Nx.backend_transfer(t) == Nx.tensor([[0, 1, 2], [3, 4, 5]], backend: Nx.BinaryBackend)
    end

    test "random_uniform" do
      t = Nx.random_uniform({30, 50})

      t
      |> Nx.backend_transfer()
      |> Nx.to_flat_list()
      |> Enum.all?(&(&1 > 0.0 and &1 < 1.0))
    end

    test "random_uniform with range" do
      t = Nx.random_uniform({30, 50}, 7, 12)

      t
      |> Nx.backend_transfer()
      |> Nx.to_flat_list()
      |> Enum.all?(&(&1 > 7.0 and &1 < 12.0))
    end

    test "random_normal" do
      t = Nx.random_normal({30, 50})

      t
      |> Nx.backend_transfer()
      |> Nx.to_flat_list()
      |> Enum.all?(&(&1 > 0.0 and &1 < 1.0))
    end

    test "random_normal with range" do
      t = Nx.random_normal({30, 50}, 7.0, 3.0)

      t
      |> Nx.backend_transfer()
      |> Nx.to_flat_list()
      |> Enum.all?(&(&1 > 7.0 - 3.0 and &1 < 7.0 + 3.0))
    end
  end

  describe "rounding error tests" do
    test "atanh/1" do
      assert_all_close(Nx.tensor(0.5493), Nx.atanh(Nx.tensor(0.5)))
    end

    test "ceil/1" do
      assert_all_close(Nx.tensor(-0.0), Nx.ceil(Nx.tensor(-0.5)))
      assert_all_close(Nx.tensor(1.0), Nx.ceil(Nx.tensor(0.5)))
    end

    test "cos/1" do
      assert_all_close(
        Nx.tensor([-1.0, 0.4999, -1.0]),
        Nx.cos(Nx.tensor([-:math.pi(), :math.pi() / 3, :math.pi()]))
      )
    end

    test "cosh/1" do
      assert_all_close(
        Nx.tensor([11.5919, 1.6002, 11.5919]),
        Nx.cosh(Nx.tensor([-:math.pi(), :math.pi() / 3, :math.pi()]))
      )
    end

    test "erfc/1" do
      assert_all_close(
        Nx.tensor([1.0, 0.4795, 0.0]),
        Nx.erfc(Nx.tensor([0, 0.5, 10_000]))
      )
    end

    test "erf_inv/1" do
      assert_all_close(
        Nx.tensor([0.0, 0.4769, 0.8134]),
        Nx.erf_inv(Nx.tensor([0, 0.5, 0.75]))
      )
    end

    test "round/1" do
      assert_all_close(
        Nx.tensor([-2.0, -0.0, 0.0, 2.0]),
        Nx.round(Nx.tensor([-1.5, -0.5, 0.5, 1.5]))
      )
    end

    test "logistic/1" do
      assert_all_close(
        Nx.tensor([0.1824, 0.6224]),
        Nx.logistic(Nx.tensor([-1.5, 0.5]))
      )
    end
  end
end
