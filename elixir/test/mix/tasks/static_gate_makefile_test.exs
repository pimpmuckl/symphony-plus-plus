defmodule Mix.Tasks.StaticGateMakefileTest do
  use ExUnit.Case, async: true

  @elixir_root Path.expand("../../..", __DIR__)

  test "static alias keeps fast PR checks separate from expensive gates" do
    aliases = Mix.Project.config()[:aliases]

    assert aliases[:static] == ["format --check-formatted", "lint"]
    assert aliases[:lint] == ["specs.check", "credo --strict"]
    assert aliases[:hygiene] == ["code_quality.guard"]
  end

  test "Makefile splits fast CI from heavyweight gates" do
    makefile = File.read!(Path.join(@elixir_root, "Makefile"))

    assert target(makefile, "static") == "\n\t@$(MIX) static\n"
    assert target(makefile, "ci-static") =~ "ci-prepare\n\t$(call run_ci_step,static,$(MIX) static)"
    assert target(makefile, "ci-fast") =~ "ci-prepare\n\t$(call run_ci_step,static,$(MIX) static)"
    assert target(makefile, "ci-fast") =~ "$(call run_ci_step,test,$(MIX) test --exclude ci_slow)"
    assert target(makefile, "ci-dialyzer") =~ "ci-prepare\n\t$(call run_ci_step,dialyzer,$(MIX) dialyzer --format short)"
    assert target(makefile, "ci-coverage") =~ "ci-prepare\n\t$(call run_ci_step,coverage,$(MIX) test --cover)"
    assert target(makefile, "ci-hygiene") =~ "\n\t$(call run_ci_step,hygiene,$(MIX) hygiene)"
    assert target(makefile, "all") == "ci-fast\n"
  end

  defp target(makefile, target) do
    pattern = ~r/^#{Regex.escape(target)}:(?: (?<dependency>.*))?\n(?<commands>(?:\t.*\n)*)/m

    case Regex.named_captures(pattern, makefile) do
      %{"commands" => commands, "dependency" => dependency} -> "#{dependency}\n#{commands}"
      nil -> flunk("missing Makefile target #{target}")
    end
  end
end
