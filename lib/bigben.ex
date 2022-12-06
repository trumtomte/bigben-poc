defmodule BigBen do
  @moduledoc """
  Documentation for `BigBen`.

  TODO: Make tests for the different modules (parsing first)
  TODO: Add typespecs, doctests, etc.
  TODO: Try to build a binary
  TODO: Add support for arguments to the binary? Ie. magnet/torrent file
  TODO: Make a custom file format for storing the download progress (within the
        same file), so we can resume/pause, and restore in case of a crash. Bencode?
  NOTE: should all other GenServers start supervised?
  """

  alias BigBen.Torrent
  alias BigBen.PieceQueue
  alias BigBen.PeerManager
  alias BigBen.Download
  alias BigBen.TrackerManager

  def test do
    TrackerManager.start_link()
    PeerManager.start_link()
    Torrent.start_link()
    PieceQueue.start_link()
    Download.start_link()

    # Torrent.load("path/to/file.torrent")
    Torrent.load("REPLACE WITH A MAGNET URI")

    Download.open(Torrent.name())

    # If we dont do this, Peers will start downloading the metadata at a later
    # stage, and then we queue the pieces
    if Torrent.has_metadata?() do
      PieceQueue.queue(Torrent.pieces())
    end

    # NOTE: Testing a local peer
    peers = [{{127, 0, 0, 1}, 38797}]
    PeerManager.start(peers)

    # Otherwise this is enough
    # TrackerManager.announce(Torrent.trackers())
  end
end
