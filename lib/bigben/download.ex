defmodule BigBen.Download do
  @moduledoc """
  Represents the file to be downloaded, handles i/o

  TODO: Test torrents with multiple files/a folder of files
  TODO: move calls to Torrent.x in `write` and `verify_piece` and store them
        within the state instead
  """

  use GenServer
  alias BigBen.Torrent

  # Client

  def start_link() do
    initial_state = %{file: nil}
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def open(name) do
    GenServer.call(__MODULE__, {:open, name})
  end

  def write(index, begin, block) do
    GenServer.cast(__MODULE__, {:write, {index, begin, block}})
  end

  def valid_piece?(index) do
    GenServer.call(__MODULE__, {:verify_piece, index})
  end

  def close do
    GenServer.cast(__MODULE__, :close)
  end

  # Server

  @impl true
  def init(state) do
    # {:ok, state, {:continue, :open}}
    {:ok, state}
  end

  @impl true
  def handle_call({:open, _name}, _from, %{file: file} = state) when file != nil do
    # Cant open more then one file
    {:reply, :ok, state}
  end

  def handle_call({:open, name}, _from, state) do
    IO.puts("[Download] Opening file #{inspect(name)}")
    opts = [:binary, :read, :write]

    case File.open(name, opts) do
      {:ok, file} ->
        {:reply, :ok, %{state | file: file}}

      # TODO: could possibly cache the piece_length, however it might not be available
      # {:reply, :ok, %{state | file: file}, {:continue, :cache_piece_length}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:verify_piece, index}, _from, %{file: file} = state) do
    piece_length = Torrent.piece_length()
    piece_hash = Torrent.piece_hash(index)
    location = index * piece_length

    case :file.pread(file, location, piece_length) do
      {:ok, data} ->
        {:reply, :crypto.hash(:sha, data) == piece_hash, state}

      # :eof, {:error, reason}
      _ ->
        # FIXME: what do we do with an invalid hash? cancel it and retry?
        {:reply, false, state}
    end
  end

  @impl true
  def handle_cast({:write, {index, begin, block}}, %{file: file} = state)
      when file != nil do
    piece_length = Torrent.piece_length()
    location = index * piece_length + begin

    case :file.pwrite(file, location, block) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        # FIXME: this would corrupt the file, what would be a good response?
        IO.puts("[Download]: Unable to write #{reason} block: index #{index}, begin #{begin}")

        {:noreply, state}
    end
  end

  def handle_cast(:close, %{file: file} = state) when file != nil do
    IO.puts("[Download]: Closing file")
    File.close(file)
    {:noreply, state}
  end

  def handle_cast(:close, state) do
    {:noreply, state}
  end

  # @impl true
  # def handle_continue(:open, %{file: file} = state) when file == nil do
  #   IO.puts("[Download] Opening file")

  #   opts = [:binary, :read, :write]
  #   name = Torrent.name()

  #   case File.open(name, opts) do
  #     {:ok, file} ->
  #       {:noreply, %{state | file: file}}

  #     {:error, reason} ->
  #       IO.puts("[Download]: Unable to open the file #{inspect(name)}: #{inspect(reason)}")
  #       {:stop, :normal, state}
  #   end
  # end
end
