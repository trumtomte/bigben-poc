defmodule BigBen.Parser do
  @moduledoc """
  Bencode Decoder

  FIXME: rename into Decoder
  NOTE: use atoms for errors instead?
  """

  @digits ~c(0123456789)

  def decode(iodata) do
    case parse(iodata) do
      {_type, value, ""} ->
        {:ok, value}

      {_type, _value, _rest} ->
        {:error, "Invalid format of iodata"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode_with_rest(iodata) do
    case parse(iodata) do
      {_type, value, rest} ->
        {:ok, value, rest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode!(iodata) do
    case parse(iodata) do
      {_type, value, ""} ->
        value

      {_type, _value, _rest} ->
        {:error, "Invalid format of iodata"}

      {:error, reason} ->
        raise reason
    end
  end

  @doc """
  Parses `iodata` into strings, integers, lists and dictionaries.
  """
  def parse(iodata)

  def parse("d" <> dict), do: parse_dict(dict)
  def parse("l" <> list), do: parse_list(list)

  def parse("i-" <> int) do
    with {:int, int, rest} <- parse_int(int),
         do: {:int, -int, rest}
  end

  def parse("i" <> int), do: parse_int(int)

  def parse(<<c>> <> _ = str) when c in @digits, do: parse_str(str)

  def parse(_iodata) do
    {:error, "Invalid format of iodata"}
  end

  defp parse_str(<<c, rest::binary>>) when c in @digits do
    parse_str(rest, <<c>>)
  end

  defp parse_str(<<c, rest::binary>>, size) when c in @digits do
    parse_str(rest, size <> <<c>>)
  end

  defp parse_str(":" <> str, size) do
    case Integer.parse(size, 10) do
      {size, _} when size <= byte_size(str) ->
        <<value::binary-size(size), rest::binary>> = str
        {:str, to_string(value), rest}

      _ ->
        {:error, "Unable to parse string size"}
    end
  end

  defp parse_str(_rest, _size) do
    {:error, "Invalid string format"}
  end

  defp parse_int("i-0e" <> _int) do
    {:error, "Invalid integer format (i-0e)"}
  end

  defp parse_int("i0" <> <<c, _rest::binary>>) when c in @digits do
    {:error, "Invalid integer format (leading zeroes)"}
  end

  defp parse_int(<<c, rest::binary>>) when c in @digits do
    parse_int(rest, <<c>>)
  end

  defp parse_int(_int) do
    {:error, "Invalid integer format (no digits)"}
  end

  defp parse_int(<<c, rest::binary>>, int) when c in @digits do
    parse_int(rest, int <> <<c>>)
  end

  defp parse_int("e" <> rest, int) do
    case Integer.parse(int, 10) do
      {int, _} ->
        {:int, int, rest}

      :error ->
        {:error, "Unable to parse integer"}
    end
  end

  defp parse_int(_rest, _acc) do
    {:error, "Invalid integer format (no end)"}
  end

  defp parse_list(values, list \\ [])
  defp parse_list("e" <> rest, list), do: {:list, list, rest}

  defp parse_list(values, list) do
    with {_type, value, rest} <- parse(values),
         do: parse_list(rest, list ++ [value])
  end

  defp parse_dict(values, dict \\ %{})
  defp parse_dict("e" <> rest, dict), do: {:dict, dict, rest}

  defp parse_dict(values, dict) do
    # NOTE: dictionary keys must be strings
    with {:str, key, rest} <- parse_str(values),
         {_type, value, rest} <- parse(rest) do
      dict = Map.put(dict, key, value)
      parse_dict(rest, dict)
    end
  end
end
