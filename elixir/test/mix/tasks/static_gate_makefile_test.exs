defmodule Mix.Tasks.StaticGateMakefileTest do
  use ExUnit.Case, async: true

  @elixir_root Path.expand("../../..", __DIR__)

  test "static alias keeps all dev static checks in one Mix invocation" do
    aliases = Mix.Project.config()[:aliases]

    assert aliases[:static] == ["format --check-formatted", "lint", "dialyzer --format short"]
  end

  test "Makefile all reuses static bundle without duplicate Dialyzer deps.get" do
    makefile = File.read!(Path.join(@elixir_root, "Makefile"))

    assert target_body(makefile, "static") == "\t@$(MIX) static\n"
    assert target_body(makefile, "ci") =~ "$(call run_ci_step,static,$(MIX) static)"
    assert target_body(makefile, "ci") =~ "$(call run_ci_step,coverage,$(MIX) test --cover)"
    refute target_body(makefile, "ci") =~ "deps.get &&"
  end

  defp target_body(makefile, target) do
    pattern = ~r/^#{Regex.escape(target)}:\n(?<body>(?:\t.*\n)+)/m

    case Regex.named_captures(pattern, makefile) do
      %{"body" => body} -> body
      nil -> flunk("missing Makefile target #{target}")
    end
  end
end
