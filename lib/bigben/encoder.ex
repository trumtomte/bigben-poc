defmodule BigBen.Encoder do
  @moduledoc """
  Bencode Encoder

  TODO: might need more guards, more testing is needed
  """

  def encode(data) do
    case bencode(data) do
      {:error, reason} ->
        {:error, reason}

      result ->
        {:ok, result}
    end
  end

  def encode!(data) do
    case bencode(data) do
      {:error, reason} ->
        raise reason

      result ->
        result
    end
  end

  @doc """
  Encodes `data` into an "bencoded" binary (str)
  """
  def bencode(data) when is_map(data), do: bencode_dict(data)
  def bencode(data) when is_list(data), do: bencode_list(data)
  def bencode(data) when is_integer(data), do: bencode_int(data)
  def bencode(data) when is_bitstring(data), do: bencode_str(data)
  def bencode(_data), do: {:error, "Invalid format"}

  defp bencode_dict(dict) do
    str =
      for {key, val} <- dict, into: "" do
        bencode(to_string(key)) <> bencode(val)
      end

    "d" <> str <> "e"
  end

  defp bencode_list(list) do
    str =
      for val <- list, into: "" do
        bencode(val)
      end

    "l" <> str <> "e"
  end

  defp bencode_int(int) do
    "i" <> to_string(int) <> "e"
  end

  defp bencode_str(str) when is_binary(str) do
    bencode_str(str, byte_size(str))
  end

  defp bencode_str(str) do
    bencode_str(str, String.length(str))
  end

  defp bencode_str(str, size) do
    to_string(size) <> ":" <> str
  end
end
