defmodule BigBen.Peer do
  @moduledoc """
  Represents a connection to a peer (i.e. a client)
  """
  use GenServer

  alias BigBen.Download
  alias BigBen.PieceQueue
  alias BigBen.PeerManager
  alias BigBen.Torrent
  alias BigBen.Parser
  alias BigBen.Encoder

  # Client

  def start_link(peer) do
    # TODO: add recieved_handshake?
    initial_state = %{
      socket: nil,
      peer: peer,
      # TCP packet buffer
      buffer: <<>>,
      # Available pieces from the peer (seeder)
      pieces: [],
      retries: 0,
      # Current block index
      index: nil,
      choked: true,
      interested: false
    }

    GenServer.start_link(__MODULE__, initial_state)
  end

  # Server

  @impl true
  def init(state) do
    # Move this into a seperate method? Peer.connect(peer)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{peer: {address, port}} = state) do
    IO.puts("[TCP #{inspect(self())}] Connecting to #{inspect(address)} #{inspect(port)}")

    opts = [:binary, active: true]

    case :gen_tcp.connect(address, port, opts) do
      {:ok, socket} ->
        IO.puts("[TCP #{inspect(self())}] Connection successful")
        {:noreply, %{state | socket: socket}, {:continue, :handshake}}

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  def handle_continue(:handshake, %{socket: socket} = state) do
    info_hash = Torrent.info_hash()
    peer_id = PeerManager.peer_id()
    packet = handshake_packet(info_hash, peer_id)

    IO.puts("[TCP #{inspect(self())}] Sending HANDSHAKE")

    case :gen_tcp.send(socket, packet) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  def handle_continue(:interested, %{socket: socket} = state) do
    packet = interested_packet()

    IO.puts("[TCP #{inspect(self())}] Sending INTERESTED")

    case :gen_tcp.send(socket, packet) do
      :ok ->
        {:noreply, %{state | interested: true}}

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  def handle_continue({:verify_piece_hash, index}, state) do
    if Download.valid_piece?(index) do
      {:noreply, state, {:continue, {:have, index}}}
    else
      # TODO: cancel/reset the piece?
      {:noreply, state, {:continue, :request}}
    end
  end

  def handle_continue({:have, index}, %{socket: socket} = state) do
    IO.puts("[TCP #{inspect(self())}] Piece hash verified, sending HAVE (#{inspect(index)})")
    packet = have_packet(index)

    # NOTE: we'll silently fail if our HAVE isnt sent
    :gen_tcp.send(socket, packet)
    {:noreply, state, {:continue, :request}}
  end

  def handle_continue(:request, %{choked: choked} = state) when choked == true do
    {:noreply, state}
  end

  def handle_continue(:request, %{interested: interested} = state)
      when interested == false do
    {:noreply, state}
  end

  # FIXME: this might be to short of a time since it takes time downloading the meta data
  def handle_continue(:request, %{retries: retries} = state) when retries > 10 do
    disconnect(state, "[Peer #{inspect(self())}] Max number of retries has been met")
  end

  def handle_continue(:request, %{socket: socket, pieces: pieces, retries: retries} = state) do
    # NOTE: wait
    # TODO: cache this!
    if not Torrent.has_metadata?() and Torrent.received_metadata_handshake?() do
      # TODO: need to check if we've received the handshake as well?
      {:noreply, state, {:continue, :request_metadata}}
    else
      if PieceQueue.received_all?() do
        disconnect(state, "#{inspect(self())} Finished download")
      else
        case PieceQueue.pop(pieces) do
          nil ->
            # NOTE: this is incase we're still waiting for the torrent meta data
            # TODO: this needs its own handle_info
            # Process.send_after(self(), :request, 1000)
            {:noreply, %{state | index: nil, retries: retries + 1}}

          {block_index, {piece, begin, length}} ->
            # IO.puts("[TCP #{inspect(self())}] Sending REQUEST: #{piece}, #{begin}, #{length}")

            PieceQueue.request(block_index)
            packet = request_packet(piece, begin, length)

            case :gen_tcp.send(socket, packet) do
              :ok ->
                {:noreply, %{state | index: block_index}}

              {:error, reason} ->
                PieceQueue.cancel(block_index)
                disconnect(state, reason)
            end
        end
      end
    end
  end

  # TODO: we should not forget we might need to fetch more peers if we cant get
  # the metadata, the peers that wont give us the metadata should still be kept
  # since they might be able to give us the torrent
  def handle_continue(:request_metadata, %{socket: socket} = state) do
    if Torrent.has_metadata?() do
      {:noreply, state, {:continue, :request}}
    else
      case Torrent.next_metadata_piece() do
        nil ->
          IO.puts("got nil metadata piece")
          {:noreply, state}

        piece ->
          id = Torrent.metadata_message_id()
          message = %{"msg_type" => 0, "piece" => piece}
          packet = extended_message_packet(id, message)
          IO.inspect("sending packet #{inspect(packet)}")

          case :gen_tcp.send(socket, packet) do
            :ok ->
              IO.puts("[TCP #{inspect(self())}] Req METADATA(#{inspect(id)}) #{inspect(message)}")
              {:noreply, state}

            {:error, reason} ->
              # FIXME: cancel the piece
              IO.puts("[TCP #{inspect(self())}] Unable to send METADATA #{inspect(message)}")
              disconnect(state, reason)
          end
      end
    end
  end

  # Handshake
  @impl true
  def handle_info(
        {:tcp, _socket,
         <<19, "BitTorrent protocol", _res::64, info_hash::binary-size(20), _id::binary>>},
        state
      ) do
    if Torrent.valid_info_hash?(info_hash) do
      IO.puts("[TCP #{inspect(self())}] Received HANDSHAKE")
      {:noreply, state}
    else
      disconnect(state, "[TCP #{inspect(self())}] Received HANDSHAKE with an invalid info_hash")
    end
  end

  # Received a whole message
  def handle_info({:tcp, _socket, <<size::32, rest::binary>> = data}, %{buffer: <<>>} = state)
      when size == byte_size(rest) do
    handle_message(data, state)
  end

  # Start a new message buffer
  def handle_info({:tcp, _socket, <<size::32, rest::binary>> = data}, %{buffer: <<>>} = state)
      when size != byte_size(rest) do
    {:noreply, %{state | buffer: data}}
  end

  # Received a whole buffered message
  def handle_info({:tcp, _socket, data}, %{buffer: <<size::32, rest::binary>> = buffer} = state)
      when size == byte_size(rest <> data) do
    message = buffer <> data
    new_state = %{state | buffer: <<>>}
    handle_message(message, new_state)
  end

  # Continue buffering
  def handle_info({:tcp, _socket, data}, %{buffer: <<size::32, rest::binary>> = buffer} = state)
      when size != byte_size(rest <> data) do
    {:noreply, %{state | buffer: buffer <> data}}
  end

  def handle_info({:tcp, _socket, _data}, state) do
    IO.puts("[TCP #{inspect(self())}] Unhandled packet")
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    disconnect(state, "[TCP #{inspect(self())}] Connection closed")
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    disconnect(state, "[TCP #{inspect(self())}] Error #{inspect(reason)}")
  end

  def handle_info(message, state) do
    IO.puts("[TCP #{inspect(self())}] Unhandled message #{inspect(message)}")
    {:noreply, state}
  end

  def handle_message(<<0::32>>, state) do
    IO.puts("[TCP #{inspect(self())}] Received KEEP-ALIVE")
    {:noreply, state}
  end

  def handle_message(<<_size::32, 0>>, state) do
    IO.puts("[TCP #{inspect(self())}] Received CHOKE")
    # NOTE: Will our message buffer make us crash after a choke/unchoke?
    {:noreply, %{state | choked: true}}
  end

  def handle_message(<<_size::32, 1>>, %{interested: interested} = state)
      when interested == true do
    IO.puts("[TCP #{inspect(self())}] Received UNCHOKE")
    {:noreply, %{state | choked: false}, {:continue, :request}}
  end

  def handle_message(<<_size::32, 1>>, state) do
    IO.puts("[TCP #{inspect(self())}] Received UNCHOKE")
    {:noreply, %{state | choked: false}}
  end

  # NOTE: We dont yet use these
  def handle_message(<<_size::32, 2>>, state) do
    IO.puts("[TCP #{inspect(self())}] Received INTERESTED")
    {:noreply, state}
  end

  # NOTE: We dont yet use these
  def handle_message(<<_size::32, 3>>, state) do
    IO.puts("[TCP #{inspect(self())}] Received NOT INTERESTED")
    {:noreply, state}
  end

  def handle_message(<<_size::32, id>>, state) do
    IO.puts("[TCP #{inspect(self())}] Recieved <UKNOWN ID ##{id}")
    {:noreply, state}
  end

  def handle_message(<<_size::32, 4, piece::binary>>, %{pieces: pieces} = state) do
    IO.puts("[TCP #{inspect(self())}] Recieved HAVE: #{inspect(piece)}")

    if piece not in pieces do
      {:noreply, %{state | pieces: pieces ++ [piece]}}
    else
      {:noreply, %{state | pieces: pieces}}
    end
  end

  def handle_message(<<_size::32, 5, bitfield::binary>>, state) do
    IO.puts("[TCP #{inspect(self())}] Received BITFIELD: #{inspect(bit_size(bitfield))}")
    # TODO: check with PieceQueue if any of the pieces are still needed, if not
    #       we should respond with :not_interested and disconnect
    {:noreply, %{state | pieces: bitfield_to_pieces(bitfield)}, {:continue, :interested}}
  end

  def handle_message(
        <<_size::32, 7, index::32, begin::32, block::binary>>,
        %{index: block_index} = state
      ) do
    IO.puts("[TCP #{inspect(self())}] recv PIECE {#{index}, #{begin}, ...}")
    PieceQueue.received(block_index)
    Download.write(index, begin, block)

    if PieceQueue.received_piece?(index) do
      {:noreply, %{state | index: nil}, {:continue, {:verify_piece_hash, index}}}
    else
      {:noreply, %{state | index: nil}, {:continue, :request}}
    end
  end

  def handle_message(<<_size::32, 8, index::32, begin::32, length::32>>, state) do
    IO.puts(
      "[TCP #{inspect(self())}] Received CANCEL: index #{index}, begin #{begin}, length #{length}"
    )

    # FIXME: calculate block_index from `index` and `begin`
    #        clear `index` in state as well
    # PieceQueue.cancel(block_index)
    {:noreply, state}
  end

  # NOTE: Extension protocol handshake
  def handle_message(<<_size::32, 20, 0, message::binary>>, state) do
    # TODO: store the message id from, eg., ut_metadata
    IO.puts("[TCP #{inspect(self())}] Received EXTENDED HANDSHAKE")
    {:ok, handshake} = Parser.decode(message)
    IO.puts("[TCP #{inspect(self())}] #{inspect(handshake)}")

    if Torrent.has_metadata?() do
      # NOTE: could this result in us being unable to send through our socket if
      # a request is in progress?
      {:noreply, state, {:continue, :request}}
    else
      Torrent.received_metadata_handshake(handshake)
      {:noreply, state, {:continue, :request_metadata}}
    end

    # TODO: better control for this
    # message_id = handshake["m"]["ut_metadata"]
    # if not Torrent.has_metadata?() and message_id != nil do
    #   Torrent.received_metadata_handshake(handshake)
    #   {:noreply, state, {:continue, :request_metadata}}
    # else
    #   {:noreply, state}
    # end
  end

  # NOTE: Extension protocol message
  def handle_message(<<_size::32, 20, id::8, message::binary>>, state) do
    IO.puts("[TCP #{inspect(self())}] Received EXTENDED MESSAGE (id #{inspect(id)})")
    IO.puts("[TCP #{inspect(self())}] #{inspect(Parser.decode_with_rest(message))}")

    if Torrent.has_metadata?() do
      {:noreply, state, {:continue, :request}}
    else
      # TODO: improve
      case Parser.decode_with_rest(message) do
        {:ok, message, data} ->
          Torrent.received_metadata_piece(message["piece"], data)

          if Torrent.has_metadata?() do
            # FIXME: requeue the queue
            PieceQueue.queue(Torrent.pieces())
            {:noreply, state, {:continue, :request}}
          else
            {:noreply, state, {:continue, :request_metadata}}
          end

        _ ->
          # FIXME: cancel the piece
          {:noreply, state, {:continue, :request_metadata}}
      end
    end
  end

  def handle_message(data, state) do
    IO.puts("[TCP] Received <UNKNOWN PACKET> #{inspect(data)}")
    {:noreply, state}
  end

  def disconnect(%{socket: socket} = state, reason) when socket != nil do
    IO.puts("[TCP #{inspect(self())}] Stopping [#{inspect(reason)}]")
    IO.puts("[TCP #{inspect(self())}] Closing TCP socket")

    :gen_tcp.close(socket)
    {:stop, :normal, state}
  end

  def disconnect(state, reason) do
    IO.puts("[TCP #{inspect(self())}] Stopping [#{inspect(reason)}]")
    {:stop, :normal, state}
  end

  defp handshake_packet(info_hash, peer_id) do
    left = <<19, "BitTorrent protocol">>
    # Set bit 20 to 1, ie. we support the extension protocol
    # reserved = <<0, 0, 0, 0, 0, 16, 0, 0>>

    # ut_metadata
    # reserved = <<0::44, 1::1, 0::19>>
    reserved = <<0::43, 1::1, 0::20>>

    right = <<info_hash::binary-size(20), peer_id::binary-size(20)>>
    left <> reserved <> right
  end

  defp request_packet(index, begin, length) do
    <<13::32, 6, index::32, begin::32, length::32>>
  end

  defp interested_packet do
    <<1::32, 2>>
  end

  defp have_packet(index) do
    <<5::32, 4, index::32>>
  end

  defp extended_message_packet(id, message) do
    message = Encoder.encode!(message)
    size = byte_size(message)
    length = size + 2
    <<length::32, 20, id::8, message::binary-size(size)>>
  end

  defp bitfield_to_pieces(bitfield) do
    bits = for <<bit::1 <- bitfield>>, do: bit
    for {bit, i} <- Enum.with_index(bits), bit == 1, do: i
  end

  # defp supports_extension_protocol(<<_left::43, 1::1, _right::20>>), do: true
  # defp supports_extension_protocol(_reserved), do: false

  # NOTE: do we want to dispatch like this?
  # case message do
  #   <<0::32>> ->
  #     keep_alive(state)

  #   <<_size::32, 0::8>> ->
  #     choke(state)

  #   <<_size::32, 1::8>> ->
  #     unchoke(state)

  #   <<_size::32, 8::8, index::32, begin::32, length::32>> ->
  #     piece({index, begin ,length}, state)
  # end

  # NOTE: rest is unused functions (just implemented from spec)

  # def handle_message(<<_size::32, 6::8, index::32, begin::32, length::32>>, state) do
  #   IO.puts("[TCP] Received REQUEST: index #{index}, begin #{begin}, length #{length}")
  #   {:noreply, state}
  # end

  # def handle_message(<<_size::32, 9::8, port::32>>, state) do
  #   IO.puts("[TCP] Recieved PORT: #{port}")
  #   {:noreply, state}
  # end
  #
  # def handle_message(<<_size::32, 8::8, index::32, begin::32, length::32>>, state) do
  #   IO.puts("[TCP] Recieved CANCEL: index #{index}, begin #{begin}, length #{length}")
  #   {:noreply, state}
  # end

  # Messages in the protocol take the form of:
  #     <length prefix><message ID><payload>.
  # The length prefix is a four byte big-endian value. The message ID is a
  # single decimal byte. The payload is message dependent. All later integers
  # sent in the protocol are encoded as four bytes big-endian.

  # def keep_alive do
  #   <<0::32>>
  # end

  # def choke do
  #   <<1::32, 0::8>>
  # end

  # def unchoke do
  #   <<1::32, 1::8>>
  # end

  # def interested do
  #   <<1::32, 2::8>>
  # end

  # def uninterested do
  #   <<1::32, 3::8>>
  # end

  # def have(piece_index) do
  #   <<5::32, 4::8, piece_index::32>>
  # end

  # def bitfield(pieces) do
  #   size = 1 + byte_size(pieces)
  #   <<size::32, 5::8, pieces::binary>>
  # end

  # def piece_packet(index, begin, block) do
  #   size = 9 + byte_size(block)
  #   <<size::32, 7::8, index::32, begin::32, block::binary>>
  # end

  # def cancel(index, begin, length) do
  #   <<13::32, 8::8, index::32, begin::32, length::32>>
  # end

  # def port(listen_port) do
  #   <<3::32, 9::8, listen_port::32>>
  # end
end
