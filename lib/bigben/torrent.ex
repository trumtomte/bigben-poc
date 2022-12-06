defmodule BigBen.Torrent do
  @moduledoc """
  Represents a torrent with its metainfo

  TODO: after initialization (read .torrent/parse magnet link) make sure we're
  either complete or incomplete (fetch meta data or not)
  NOTE: for now we take for granted that all magnet links include a display name
  """

  use GenServer
  alias BigBen.Parser
  alias BigBen.Encoder
  alias BigBen.Magnet

  # Client

  def start_link() do
    # TODO: if no other state is needed flatten it once
    # TODO: add `metadata` as a message buffer when receiving Extended Messsages?
    initial_state = %{
      torrent: nil,
      metadata_message_id: nil,
      metadata_size: nil,
      metadata_pieces: [],
      next_metadata_piece: 0
    }

    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def load(torrent) do
    GenServer.call(__MODULE__, {:load, torrent})
  end

  def valid_info_hash?(info_hash) do
    GenServer.call(__MODULE__, {:valid_info_hash?, info_hash})
  end

  def has_metadata? do
    GenServer.call(__MODULE__, :has_metadata?)
  end

  def name do
    GenServer.call(__MODULE__, :name)
  end

  def size do
    GenServer.call(__MODULE__, :size)
  end

  def info_hash do
    GenServer.call(__MODULE__, :info_hash)
  end

  def trackers do
    GenServer.call(__MODULE__, :trackers)
  end

  def piece_length do
    GenServer.call(__MODULE__, :piece_length)
  end

  def piece_hash(index) do
    GenServer.call(__MODULE__, {:piece_hash, index})
  end

  def pieces do
    GenServer.call(__MODULE__, :pieces)
  end

  def metadata_message_id do
    GenServer.call(__MODULE__, :metadata_message_id)
  end

  def next_metadata_piece do
    GenServer.call(__MODULE__, :next_metadata_piece)
  end

  def received_metadata_handshake? do
    GenServer.call(__MODULE__, :received_metadata_handshake?)
  end

  def received_metadata_handshake(handshake) do
    GenServer.cast(__MODULE__, {:received_metadata_handshake, handshake})
  end

  def received_metadata_piece(piece, data) do
    GenServer.call(__MODULE__, {:received_metadata_piece, piece, data})
  end

  # Server

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:load, "magnet:?" <> _ = magnet_link}, _from, state) do
    {:ok, torrent} = Magnet.parse(magnet_link)
    {:reply, :ok, %{state | torrent: torrent}}
  end

  def handle_call({:load, path}, _from, state) do
    {:ok, data} = File.read(path)
    {:ok, torrent} = Parser.decode(data)
    torrent = set_info_hash(torrent)
    {:reply, :ok, %{state | torrent: torrent}}
  end

  def handle_call(
        {:valid_info_hash?, hash},
        _from,
        %{torrent: %{"info_hash" => info_hash}} = state
      ) do
    {:reply, hash == info_hash, state}
  end

  def handle_call({:valid_info_hash?, _}, _from, state), do: {:reply, false, state}

  def handle_call(
        :has_metadata?,
        _from,
        %{torrent: %{"info" => %{"length" => _, "piece length" => _, "pieces" => _}}} = state
      ) do
    IO.puts("has metadata? true #{inspect(state)}")
    {:reply, true, state}
  end

  def handle_call(:has_metadata?, _from, state) do
    IO.puts("has metadata? false #{inspect(state)}")
    {:reply, false, state}
  end

  def handle_call(:name, _from, %{torrent: %{"info" => %{"name" => name}}} = state) do
    {:reply, name, state}
  end

  def handle_call(:size, _from, %{torrent: %{"info" => %{"length" => length}}} = state) do
    {:reply, length, state}
  end

  def handle_call(:size, _from, %{torrent: %{"files" => files}} = state) do
    # NOTE: This could be calculated from "piece length" and the amount of pieces
    size = Enum.reduce(files, 0, fn %{"length" => length}, size -> length + size end)
    {:reply, size, state}
  end

  def handle_call(:size, _from, state), do: {:reply, nil, state}

  def handle_call(:info_hash, _from, %{torrent: %{"info_hash" => info_hash}} = state) do
    {:reply, info_hash, state}
  end

  def handle_call(
        :piece_length,
        _from,
        %{torrent: %{"info" => %{"piece length" => piece_length}}} = state
      ) do
    {:reply, piece_length, state}
  end

  def handle_call(:piece_length, _from, state), do: {:reply, nil, state}

  def handle_call(
        {:piece_hash, index},
        _from,
        %{torrent: %{"info" => %{"pieces" => pieces}}} = state
      ) do
    piece_hash = binary_part(pieces, index * 20, 20)
    {:reply, piece_hash, state}
  end

  def handle_call({:piece_hash, _index}, _from, state), do: {:reply, nil, state}

  def handle_call(:trackers, _from, %{torrent: %{"announce-list" => trackers}} = state) do
    {:reply, List.flatten(trackers), state}
  end

  def handle_call(:trackers, _from, %{torrent: %{"announce" => tracker}} = state) do
    {:reply, [tracker], state}
  end

  # FIXME: fix length for multiple files
  def handle_call(
        :pieces,
        _from,
        %{
          torrent: %{
            "info" => %{"length" => length, "pieces" => pieces, "piece length" => piece_length}
          }
        } = state
      ) do
    piece_indexes = round(byte_size(pieces) / 20) - 1
    block_indexes = round(piece_length / 16384) - 1
    last_length = Integer.mod(length, 16384)

    pieces =
      for piece <- 0..piece_indexes,
          block <- 0..block_indexes do
        if piece == piece_indexes and block == block_indexes do
          {piece, block * 16384, last_length}
        else
          {piece, block * 16384, 16384}
        end
      end

    {:reply, pieces, state}
  end

  def handle_call(:pieces, _from, state), do: {:reply, [], state}

  def handle_call(:metadata_message_id, _from, %{metadata_message_id: id} = state) do
    {:reply, id, state}
  end

  def handle_call(
        :next_metadata_piece,
        _from,
        %{metadata_size: metadata_size, next_metadata_piece: next} = state
      ) do
    # if metadata_complete?(state) do

    if next + 1 > round(metadata_size / 16384) do
      {:reply, nil, state}
    else
      {:reply, next, %{state | next_metadata_piece: next + 1}}
    end
  end

  def handle_call(:received_metadata_handshake?, _from, %{metadata_size: size} = state)
      when size != nil do
    IO.puts("received metadata handshake")
    {:reply, true, state}
  end

  def handle_call(:received_metadata_handshake?, _from, state) do
    IO.puts("didnt receive metadata handshake")
    {:reply, false, state}
  end

  # NOTE: could there be the case of duplication?
  def handle_call(
        {:received_metadata_piece, piece, data},
        _from,
        %{metadata_pieces: pieces} = state
      ) do
    metadata_pieces = pieces ++ [{piece, data}]
    new_state = %{state | metadata_pieces: metadata_pieces}

    # FIXME: should we have a separare "is buffer complete" and the "no more pieces to request"
    if metadata_complete?(new_state) do
      if state["torrent"]["info"]["pieces"] == nil do
        metadata =
          metadata_pieces
          |> Enum.sort(fn {a, _}, {b, _} -> b > a end)
          |> Enum.reduce(<<>>, fn {_, data}, buffer -> buffer <> data end)
          |> Parser.decode!()

        IO.puts("Got all of the metadata #{inspect(metadata)}")

        torrent = Map.merge(Map.get(state, "torrent", %{}), %{"info" => metadata})
        IO.puts("This is the new torrent #{inspect(torrent)}")
        {:reply, :ok, %{state | torrent: torrent}}
      else
        IO.puts("Already have all the metadata")
        {:reply, :ok, new_state}
      end
    else
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast({:received_metadata_handshake, _handshake}, %{metadata_size: size} = state)
      when size != nil do
    {:noreply, state}
  end

  def handle_cast(
        {:received_metadata_handshake, %{"m" => %{"ut_metadata" => id}, "metadata_size" => size}},
        state
      ) do
    {:noreply, %{state | metadata_size: size, metadata_message_id: id}}
  end

  defp metadata_complete?(%{metadata_size: metadata_size, metadata_pieces: pieces}) do
    # FIXME: we can also just divide total_size / 16kb and check if we have that many (count) pieces
    buffer_size =
      pieces
      |> Enum.sort(fn {a, _}, {b, _} -> b > a end)
      |> Enum.reduce(<<>>, fn {_, data}, buffer -> buffer <> data end)
      |> byte_size()

    IO.puts("buffer size #{inspect(buffer_size)}, metadata_size #{inspect(metadata_size)}")

    buffer_size == metadata_size
  end

  defp set_info_hash(%{"info" => info} = map) do
    with {:ok, bencode} <- Encoder.encode(info),
         hash <- :crypto.hash(:sha, bencode),
         do: Map.put(map, "info_hash", hash)
  end

  defp set_info_hash(_torrent), do: :error

  # TODO: we could pattern match if its a magnet or not? otherwise read file
  # def from_magnet(magnet) do
  #   # FIXME: this should result in an incomplete torrent since we now need to
  #   # fetch the rest of the meta data
  #   {:ok, result} = Magnet.parse(magnet)
  #   result
  # end

  # def read(_path) do
  #   :not_implemented
  # end

  # def read!(path) do
  #   # NOTE: rewrite later on
  #   path
  #   |> File.read!()
  #   |> parse()
  # end

  # def parse(iodata) do
  #   iodata
  #   |> Parser.decode!()
  #   |> set_info_hash()
  # end

  # def name(torrent)
  # def name(%{"info" => %{"name" => name}}), do: name
  # def name(_torrent), do: nil

  # def info_hash(%{"info_hash" => info_hash}), do: info_hash
  # def info_hash(_torrent), do: nil

  # def size(%{"info" => %{"length" => length}}), do: length

  # def size(%{"info" => %{"files" => files}}) do
  #   Enum.reduce(files, 0, fn %{"length" => length}, size -> length + size end)

  #   # NOTE: Or from the pieces instead
  #   # piece_length = piece_length(torrent)
  #   # num_pieces = piece_length(torrent)
  #   # last_piece_size = Integer.mod(piece_length, num_pieces)
  #   # piece_length * (num_pieces - 1) + last_piece_size
  # end

  # def size(_torrent), do: 0

  # def trackers(torrent)

  # def trackers(%{"announce-list" => trackers}) do
  #   {:ok, List.flatten(trackers)}
  # end

  # def trackers(%{"announce" => tracker}) do
  #   {:ok, [tracker]}
  # end

  # # FIXME: could return an empty list instead?
  # def trackers(_torrent) do
  #   {:error, "No `announce-list` or `announce` key"}
  # end

  # def trackers(%{"announce-list" => trackers}, protocol) do
  #   trackers =
  #     trackers
  #     |> List.flatten()
  #     |> Enum.filter(&String.starts_with?(&1, protocol))

  #   {:ok, trackers}
  # end

  # def trackers(%{"announce" => tracker}, protocol) do
  #   trackers = [tracker] |> Enum.filter(&String.starts_with?(&1, protocol))
  #   {:ok, trackers}
  # end

  # def trackers(_torrent, _protocol) do
  #   {:error, "No `announce-list` or `announce` key"}
  # end

  # def piece_length(%{"info" => %{"piece length" => piece_length}}) do
  #   piece_length
  # end

  # def piece_length(_torrent), do: 0

  # def piece_hash(%{"info" => %{"pieces" => pieces}}, index) do
  #   binary_part(pieces, index * 20, 20)
  # end

  # def piece_hash(_torrent, _index), do: nil

  # def num_pieces(torrent)
  # # The torrent.info.pieces is a buffer that contains 20-byte SHA-1 hash of each
  # # piece, and the length gives you the total number of bytes in the buffer.
  # def num_pieces(%{"info" => %{"pieces" => pieces}}) do
  #   round(byte_size(pieces) / 20)
  # end

  # def num_pieces(_torrent), do: 0

  # def blocks_per_piece(torrent) do
  #   round(piece_length(torrent) / 16384)
  # end
end
