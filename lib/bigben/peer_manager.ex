defmodule BigBen.PeerManager do
  @moduledoc """
  Manages peer connections (i.e. our clients)
  """

  use GenServer
  alias BigBen.Peer
  alias BigBen.TrackerManager

  @peer_id "-TM0001-"
  @max_connect_threshold 25

  # Client

  def start_link do
    # Peers%{peer_addr: {peer, state}}
    #   state = :not_started | :down | pid
    GenServer.start_link(
      __MODULE__,
      %{peer_id: nil, peers: %{}},
      name: __MODULE__
    )
  end

  def peer_id do
    GenServer.call(__MODULE__, :peer_id)
  end

  def close do
    GenServer.cast(__MODULE__, :close)
  end

  def start(peers) when is_list(peers) do
    GenServer.cast(__MODULE__, {:start, peers})
  end

  def start(peer) when is_tuple(peer) do
    GenServer.cast(__MODULE__, {:start, [peer]})
  end

  # Server

  @impl true
  def init(state) do
    {:ok, state, {:continue, :generate_peer_id}}
  end

  @impl true
  def handle_continue(:generate_peer_id, state) do
    {:noreply, %{state | peer_id: @peer_id <> :crypto.strong_rand_bytes(12)}}
  end

  def handle_continue(:start_peers, %{peers: peers} = state) do
    peers = start_peers(peers)

    if more_peers_are_needed?(peers) do
      TrackerManager.next()
    end

    {:noreply, %{state | peers: peers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{peers: peers} = state) do
    case peer(peers, pid) do
      {key, {peer, _pid}} ->
        peers = Map.replace(peers, key, {peer, :down})
        {:noreply, %{state | peers: peers}, {:continue, :start_peers}}

      nil ->
        {:noreply, state, {:continue, :start_peers}}
    end
  end

  @impl true
  def handle_call(:peer_id, _from, %{peer_id: peer_id} = state) do
    {:reply, peer_id, state}
  end

  @impl true
  def handle_cast({:start, new_peers}, %{peers: peers} = state) do
    IO.puts("[PeerManager]: Adding #{inspect(Enum.count(new_peers))} new Peers")

    peers =
      Enum.reduce(new_peers, peers, fn peer, peers ->
        Map.put_new(peers, peer_addr(peer), {peer, :not_started})
      end)

    {:noreply, %{state | peers: peers}, {:continue, :start_peers}}
  end

  def handle_cast(:close, state) do
    # TODO: go through all peers and kill them
    {:stop, :normal, state}
  end

  defp start_peers(peers) do
    start_peers(peers, Map.to_list(peers))
  end

  defp start_peers(peers, []), do: peers

  defp start_peers(peers, [{_, {_, pid}} | tail])
       when is_pid(pid) or pid == :down do
    start_peers(peers, tail)
  end

  defp start_peers(peers, [{key, {peer, state}} | tail]) do
    pid =
      if peers_below_connect_threshold?(peers) do
        {:ok, pid} = Peer.start_link(peer)
        Process.monitor(pid)
        pid
      else
        state
      end

    peers = Map.replace(peers, key, {peer, pid})
    start_peers(peers, tail)
  end

  defp peer(peers, pid) do
    Enum.find(peers, fn {_, {_, state}} -> state == pid end)
  end

  defp peers_below_connect_threshold?(peers) do
    connected_peers =
      peers
      |> Map.filter(fn {_, {_, state}} -> is_pid(state) end)
      |> map_size()

    connected_peers < @max_connect_threshold
  end

  defp more_peers_are_needed?(peers) do
    available_peers =
      peers
      |> Map.reject(fn {_, {_, state}} -> state == :down end)
      |> map_size()

    available_peers < @max_connect_threshold
  end

  defp peer_addr({{p1, p2, p3, p4}, port}) do
    "#{p1}.#{p2}.#{p3}.#{p4}:#{port}"
  end
end
