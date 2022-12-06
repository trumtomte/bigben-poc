defmodule BigBen.TrackerManager do
  @moduledoc """
  Manages multiple tracker connections
  """

  use GenServer
  alias BigBen.Tracker

  def start_link do
    initial_state = %{current: 0, trackers: []}
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def announce(trackers) when is_list(trackers) do
    GenServer.cast(__MODULE__, {:announce, trackers})
  end

  def announce(tracker) when is_bitstring(tracker) do
    GenServer.cast(__MODULE__, {:announce, [tracker]})
  end

  def next do
    GenServer.cast(__MODULE__, :next)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:announce, new_trackers}, %{trackers: trackers} = state) do
    {:noreply, %{state | trackers: trackers ++ new_trackers}, {:continue, :start_trackers}}
  end

  def handle_cast(:next, %{current: current, trackers: trackers} = state)
      when current >= length(trackers) do
    # TODO: could reset `current`
    {:noreply, state}
  end

  def handle_cast(:next, state) do
    {:noreply, state, {:continue, :start_trackers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    IO.puts("[TrackerManager] #{inspect(pid)} is DOWN: #{inspect(reason)}")
    # TODO: if our tracker, eg., timed out we'd want to `continue()`
    {:noreply, state}
  end

  @impl true
  def handle_continue(:start_trackers, %{current: index, trackers: trackers} = state) do
    IO.puts("[TrackerManager]: starting tracker at #{index}")
    tracker = Enum.at(trackers, index)
    {:ok, pid} = Tracker.start_link(tracker)
    Process.monitor(pid)
    {:noreply, %{state | current: index + 1}}
  end
end
