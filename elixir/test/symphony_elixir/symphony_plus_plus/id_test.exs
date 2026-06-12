defmodule SymphonyElixir.SymphonyPlusPlus.IdTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Id

  test "random ids are compact lowercase base32 handles" do
    assert Id.random("wr") =~ ~r/^wr_[a-z2-7]{16}$/
  end

  test "random ids do not use dash-bearing base64url tokens" do
    id = Id.random("work_package")

    refute id =~ "-"
    assert id =~ ~r/^work_package_[a-z2-7]{16}$/
  end
end
