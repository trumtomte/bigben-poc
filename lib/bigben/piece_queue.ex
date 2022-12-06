defmodule BigBen.PieceQueue do
  @moduledoc """
  Represents a queue of all the torrent pieces (split into blocks even) to be
  downloaded.

  NOTE: rename to BlockQueue?
  TODO: make the difference between piece and block more obvious
  """

  use GenServer

  alias BigBen.Download

  # Client

  def start_link() do
    # State is simple the list of pieces: {piece, begin, length, state}
    #   state = 0 queued | 1 popped | 2 requested | 3 receieved
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def close do
    GenServer.cast(__MODULE__, :close)
  end

  def queue(pieces) do
    GenServer.call(__MODULE__, {:queue, pieces})
  end

  def pop(pool) do
    GenServer.call(__MODULE__, {:pop, pool})
  end

  def cancel(index) do
    GenServer.cast(__MODULE__, {:set, index, 0})
  end

  def request(index) do
    GenServer.cast(__MODULE__, {:set, index, 2})
  end

  def received(index) do
    GenServer.cast(__MODULE__, {:set, index, 3})
  end

  def received_all? do
    GenServer.call(__MODULE__, :received_all?)
  end

  def received_piece?(index) do
    GenServer.call(__MODULE__, {:received_piece?, index})
  end

  # Server

  @impl true
  def init(state) do
    # FIXME: we cant initialize unless we have all the torrent meta data. So
    # `Torrent` will have to initialize the PieceQueue when it has all its meta
    # data.
    # {:ok, state, {:continue, :initialize}}
    {:ok, state}
  end

  @impl true
  def handle_cast({:set, index, piece_state}, pieces) do
    {pieces, _piece} = set_piece_state(pieces, index, piece_state)
    {:noreply, pieces}
  end

  @impl true
  def handle_call({:queue, pieces}, _from, []) when length(pieces) > 0 do
    # Append the internal `piece_state`
    {:reply, :ok, Enum.map(pieces, &Tuple.append(&1, 0))}
  end

  def handle_call({:queue, _pieces}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:pop, []}, _from, state) do
    {:reply, nil, state}
  end

  def handle_call({:pop, _pool}, _from, []) do
    {:reply, nil, []}
  end

  # `pool` is a list of indexes accesible from the current peer connection. In
  # order to avoid a peer requesting a piece their remote peer doesnt have.
  def handle_call({:pop, pool}, _from, pieces) do
    indexes = get_queued_block_indexes(pieces, pool)

    case List.first(indexes) do
      nil ->
        {:reply, nil, pieces}

      index ->
        {pieces, piece} = set_piece_state(pieces, index, 1)
        {:reply, {index, piece}, pieces}
    end
  end

  def handle_call(:received_all?, _from, []) do
    {:reply, false, []}
  end

  def handle_call(:received_all?, _from, pieces) do
    if Enum.all?(pieces, &received?/1) do
      Download.close()
      {:reply, true, pieces}
    else
      {:reply, false, pieces}
    end
  end

  def handle_call({:received_piece?, index}, _from, pieces) do
    received_piece? =
      pieces
      |> Enum.filter(&(elem(&1, 0) == index))
      |> Enum.all?(&received?/1)

    {:reply, received_piece?, pieces}
  end

  defp set_piece_state(pieces, index, state) do
    piece = Enum.at(pieces, index) |> put_elem(3, state)
    pieces = List.replace_at(pieces, index, piece)
    # Exclude `piece_state` from the piece
    {pieces, Tuple.delete_at(piece, 3)}
  end

  defp received?(piece)
  defp received?({_, _, _, piece_state}), do: piece_state == 3

  defp get_queued_block_indexes(pieces, pool) do
    for {{piece, _, _, piece_state}, index} <- Enum.with_index(pieces),
        piece_state == 0,
        piece in pool do
      index
    end
  end

  # @impl true
  # def handle_continue(:initialize, _state) do
  #   # num_pieces = Torrent.num_pieces(torrent) - 1
  #   # blocks_per_piece = Torrent.blocks_per_piece(torrent) - 1
  #   # last_block_size = Integer.mod(Torrent.size(torrent), 16384)

  #   # # {piece, begin, length, state}
  #   # pieces =
  #   #   for piece <- 0..num_pieces,
  #   #       block <- 0..blocks_per_piece do
  #   #     if piece == num_pieces and block == blocks_per_piece do
  #   #       {piece, block * 16384, last_block_size, 0}
  #   #     else
  #   #       {piece, block * 16384, 16384, 0}
  #   #     end
  #   #   end

  #   # Append the internal piece_state to each piece
  #   {:noreply, Torrent.pieces() |> Enum.map(&Tuple.append(&1, 0))}
  # end
end
