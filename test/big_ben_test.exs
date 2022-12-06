defmodule BigBenTest do
  use ExUnit.Case
  doctest BigBen

  test "greets the world" do
    assert BigBen.hello() == :world
  end
end
