defmodule BigBen.Tracker do
  @moduledoc """
  Represents a tracker connection

  TODO: UDP time outs / retries
  TODO: rename transaction_id to tid and connection_id to cid?
  """

  use GenServer
  alias BigBen.Parser
  alias BigBen.Torrent
  alias BigBen.PeerManager

  # Client

  def start_link(url) do
    initial_state = %{
      tracker: url,
      socket: nil,
      transaction_id: nil,
      connection_id: nil
    }

    GenServer.start_link(__MODULE__, initial_state)
  end

  # Server

  @impl true
  def init(state) do
    # FIXME: this will have to be a separate method when we have a TrackerManager?
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{tracker: "http" <> _ = tracker} = state) do
    query = get_http_request_query()
    url = get_http_request_url(tracker, query)
    headers = get_http_request_headers()
    opts = get_http_request_options()

    IO.puts("[HTTP]: Connecting to #{inspect(url)}")

    # TODO: with?, if all return {:error, reason} we can use with

    case :httpc.request(:get, {url, headers}, opts, []) do
      {:ok, {{_protocol, status, _msg}, _headers, body} = response} ->
        IO.puts("Received #{inspect(response)}")

        case status do
          200 ->
            response = :erlang.list_to_binary(body)

            case Parser.decode(response) do
              {:ok, response} ->
                handle_http_tracker_response(response, state)

              _ ->
                disconnect(state, "[HTTP]: Unable to decode tracker announce response")
            end

          _ ->
            disconnect(state, "[HTTP]: Tracker announce request failed")
        end

      {:error, reason} ->
        disconnect(state, "[HTTP]: Unable to connect: #{inspect(reason)}")
    end
  end

  def handle_continue(:connect, %{tracker: "udp" <> _} = state) do
    IO.puts("[UDP]: Opening UDP connection")
    opts = [:binary, active: true, reuseaddr: true]

    # FIXME: we're reusing the same port across multiple trackers - we'll need to track this
    #        ...maybe its time to create a TrackerPool?
    case :gen_udp.open(6881, opts) do
      {:ok, socket} ->
        {:noreply, %{state | socket: socket}, {:continue, :connect_request}}

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  def handle_continue(:connect, %{tracker: tracker} = state) do
    disconnect(state, "Unknown tracker protocol: #{inspect(tracker)}")
  end

  def handle_continue(:connect_request, %{socket: socket, tracker: tracker} = state) do
    %{host: host, port: port} = URI.parse(tracker)
    host = String.to_charlist(host)
    transaction_id = get_transaction_id()
    connect_packet = get_connect_packet(transaction_id)

    IO.puts(
      "[UDP]: Sending CONNECT REQUEST (#{inspect(transaction_id)}) #{inspect(host)} #{inspect(port)}"
    )

    # TODO: time outs?

    case :gen_udp.send(socket, host, port, connect_packet) do
      :ok ->
        {:noreply, %{state | transaction_id: transaction_id}}

      {:error, reason} ->
        disconnect(state, "[UDP]: Unable to send CONNECT REQUEST: #{inspect(reason)}")
    end
  end

  def handle_continue(:announce_request, %{socket: socket, tracker: tracker} = state) do
    %{host: host, port: port} = URI.parse(tracker)
    host = String.to_charlist(host)
    # Announce is a new transaction (from connect)
    state = %{state | transaction_id: get_transaction_id()}
    announce_packet = get_announce_packet(state)

    IO.puts("[UDP]: Sending ANNOUNCE REQUEST")

    case :gen_udp.send(socket, host, port, announce_packet) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  @impl true
  def handle_info({:udp, _socket, _address, _port, data}, state) do
    handle_message(data, state)
  end

  # UDP connect response
  # TODO: we should check that the message is at least 16 bytes - seems like it could be more...
  def handle_message(
        <<0::32, transaction_id::32, connection_id::64>>,
        %{transaction_id: trans_id} = state
      )
      when trans_id == transaction_id do
    IO.puts(
      "[UDP]: Received CONNECT RESPONSE: #{inspect(transaction_id)} #{inspect(connection_id)}"
    )

    {:noreply, %{state | connection_id: connection_id}, {:continue, :announce_request}}
  end

  # UDP announce response
  # TODO: we should check that the message is at least 20 bytes
  # TODO: we should not be able to announce until X OR an event has occured (?)
  def handle_message(
        <<1::32, transaction_id::32, interval::32, _l::32, _s::32, peers::binary>>,
        %{transaction_id: trans_id} = state
      )
      when trans_id == transaction_id do
    IO.puts("[UDP]: Received ANNOUNCE RESPONSE: #{inspect(transaction_id)}")
    IO.puts("[UDP]: Interval #{inspect(interval)}")
    # add_peers_to_pool(peers)
    PeerManager.start(peers_to_list(peers))

    # NOTE: we need to keep the tracker alive in order to inform them when we downloaded everything?
    # disconnect(state, "[UDP]: Done with UDP tracker response")
    {:noreply, state}
  end

  def handle_message(<<action::32, _transaction_id::32, message::binary>>, state)
      when action == 3 do
    disconnect(state, "[UDP]: Error Response #{inspect(message)}")
  end

  def handle_message(data, state) do
    IO.puts("[UDP]: Received unhandled message #{inspect(data)}")
    {:noreply, state}
  end

  # NOTE: more keys to work with
  # interval: Interval in seconds that the client should wait between sending regular requests to the tracker
  # min interval: (optional) Minimum announce interval. If present clients must not reannounce more frequently than this.
  # tracker id: A string that the client should send back on its next announcements. If absent and a previous announce sent a
  # tracker id, do not discard the old value; keep using it.
  # complete: number of peers with the entire file, i.e. seeders (integer)
  # incomplete: number of non-seeder peers, aka "leechers" (integer)
  def handle_http_tracker_response(response, state)

  def handle_http_tracker_response(%{"failure reason" => reason}, state) do
    disconnect(state, "[HTTP]: Tracker response failure: #{reason}")
  end

  def handle_http_tracker_response(%{"peers" => peers} = response, state) do
    IO.puts("[HTTP]: Received RESPONSE: #{inspect(response)}")
    # add_peers_to_pool(peers)
    PeerManager.start(peers_to_list(peers))

    # NOTE: we need to keep the tracker alive in order to inform them when we downloaded everything?
    # disconnect(state, "[HTTP]: Done with HTTP tracker response")
    {:noreply, state}
  end

  def get_http_request_query() do
    # NOTE: event: "started"
    %{
      peer_id: PeerManager.peer_id(),
      info_hash: Torrent.info_hash(),
      left: Torrent.size(),
      port: 6881,
      compact: 1,
      uploaded: 0,
      downloaded: 0
    }
  end

  def get_http_request_url(tracker, query) do
    url = tracker <> "?" <> URI.encode_query(query, :rfc3986)
    to_charlist(url)
  end

  def get_http_request_headers do
    [{'Connection', 'close'}]
  end

  def get_http_request_options do
    #   reuse_session: false,
    #   customize_hostname_check: [
    #     match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
    #   ]
    [
      timeout: 10_000,
      ssl: [
        verify: :verify_peer,
        # FIXME: this has to be adaptable?
        cacertfile: "/etc/ssl/certs/ca-certificates.crt"
      ]
    ]
  end

  def disconnect(%{socket: socket} = state, reason) when socket != nil do
    IO.puts(reason)
    IO.puts("[UDP]: Closing UDP socket")
    :gen_udp.close(socket)
    IO.puts("Stopping tracker #{inspect(self())}")
    {:stop, :normal, state}
  end

  def disconnect(state, reason) do
    IO.puts(reason)
    IO.puts("Stopping tracker #{inspect(self())}")
    {:stop, :normal, state}
  end

  def get_transaction_id, do: :crypto.strong_rand_bytes(4)

  def peers_to_list(peers) when is_binary(peers) do
    for <<p1, p2, p3, p4, port::16 <- peers>> do
      {{p1, p2, p3, p4}, port}
    end
  end

  # Compact peer list [%Peer{"ip" => str, "port" => int, "peer id" => str}]
  def peers_to_list(peers) when is_list(peers) do
    for %{"ip" => ip, "port" => port} <- peers do
      # [p1, p2, p3, p4] = ip |> String.split(".") |> Enum.map(&String.to_integer/1)
      # {{p1, p2, p3, p4}, port}
      ip = ip |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
      {ip, port}
    end
  end

  def get_connect_packet(transaction_id) do
    <<0x41727101980::64, 0::32, transaction_id::32>>
  end

  def get_announce_packet(%{connection_id: connection_id, transaction_id: transaction_id}) do
    info_hash = Torrent.info_hash()
    peer_id = PeerManager.peer_id()
    left = Torrent.size()

    # conn_id, action, trans_id, hash, peer_id, downloaded, left, uploaded,
    # event, ip, key, num_want, port
    <<
      connection_id::64,
      1::32,
      transaction_id::32,
      info_hash::binary-size(20),
      peer_id::binary-size(20),
      0::64,
      left::64,
      0::64,
      0::32,
      0::32,
      0::32,
      -1::32,
      6887::16
    >>
  end

  # def add_peers_to_pool(peers) do
  #   # IO.puts("Peers: #{inspect(peers_to_list(peers))}")
  #   # IO.puts("Nr of peers: #{Enum.count(peers)}")
  #   PeerManager.add(peers_to_list(peers))
  # end
end
