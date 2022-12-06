defmodule BigBen.Magnet do
  @moduledoc """
  Magnet URI parsing

  Example:
    magnet:?
    xt=urn:btih:EB27A614C4DF1F60895827FEC8CF721EB3167DD3
    &dn=The%20Thing%20(1982)%20REMASTERED%20-%201080p%20BluRay%20-%206CH%20-%202GB%20-%20ShAaNiG
    &tr=udp%3A%2F%2Ftracker.coppersurfer.tk%3A6969%2Fannounce
    &tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A6969%2Fannounce
    &tr=udp%3A%2F%2F9.rarbg.to%3A2710%2Fannounce
    &tr=udp%3A%2F%2F9.rarbg.me%3A2780%2Fannounce
    &tr=udp%3A%2F%2F9.rarbg.to%3A2730%2Fannounce
    &tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337
    &tr=http%3A%2F%2Fp4p.arenabg.com%3A1337%2Fannounce
    &tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce
    &tr=udp%3A%2F%2Ftracker.tiny-vps.com%3A6969%2Fannounce
    &tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce

  From the spec/wiki:
  xt also allows for a group setting. Multiple files can be included by adding a count number preceded by a dot (".") to each link parameter.
    magnet:?xt.1=[ URN of the first file]&xt.2=[ URN of the second file]
  """

  # FIXME: rename into `decode`
  def parse("magnet:?" <> params) do
    params = String.split(params, "&", trim: true)
    decode_parameters(%{}, params)

    # TODO:
    # Instead we could perhaps just do
    # get hash (required)
    # get trackers (required)
    # get display name (optional, but for now; required)
    # if something fails its an invalid magnet link
  end

  def parse(_uri), do: {:error, "Invalid format"}

  defp decode_parameters(map, ["xt=urn:btih:" <> info_hash | tail]) do
    # NOTE: we might want to leave the String.upcase/1 to the user
    # String.upcase/1 ensures we can Base.decode16!/1 the hash
    # FIXME: error handling from decoding the hash
    hash = String.upcase(info_hash) |> Base.decode16!()
    Map.put(map, "info_hash", hash) |> decode_parameters(tail)
  end

  # NOTE: should we store everying in both the uri key and a custom key?
  #       eg. `dn` in both `dn` and `name`

  # Display name
  defp decode_parameters(map, ["dn=" <> dn | tail]) do
    name = URI.decode(dn)

    map
    |> Map.update("info", %{"name" => name}, &Map.put(&1, "name", name))
    |> decode_parameters(tail)
  end

  # Tracker
  defp decode_parameters(map, ["tr=" <> tr | tail]) do
    tracker = URI.decode(tr)

    map
    |> Map.put_new("announce", tracker)
    |> Map.update("announce-list", [tracker], &Enum.concat(&1, [tracker]))
    |> decode_parameters(tail)
  end

  defp decode_parameters(map, _params), do: {:ok, map}

  # TODO: might as well continue implementing the rest (https://en.wikipedia.org/wiki/Magnet_URI_scheme)
end
