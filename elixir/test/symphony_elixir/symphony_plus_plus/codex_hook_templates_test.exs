defmodule SymphonyElixir.SymphonyPlusPlus.CodexHookTemplatesTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @templates_dir Path.join(@repo_root, "implementation_docs_symphplusplus/templates/codex_hooks")
  @readme_path Path.join(@templates_dir, "README.md")
  @template_paths [
    Path.join(@templates_dir, "hooks.posix.json"),
    Path.join(@templates_dir, "hooks.windows.json")
  ]
  @script_path Path.join(@templates_dir, "scripts/sympp_hook_nudge.py")
  @windows_launcher_path Path.join(@templates_dir, "scripts/sympp_hook_nudge.ps1")
  @expected_events ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]

  test "hook templates are documented as optional reliability aids" do
    readme = File.read!(@readme_path)

    assert readme =~ "optional reliability aids"
    assert readme =~ "not install themselves"
    assert readme =~ "first confirm your Codex build loads"
    assert readme =~ "reference-only on builds that report Windows"
    assert readme =~ "not a permission boundary"
    assert readme =~ "Symphony++ permissions stay server-side"
    assert readme =~ "Do not embed grant secrets"
    assert readme =~ "Do not read private transcripts or chain-of-thought"
    assert readme =~ "do not echo prompts"
  end

  test "hook templates are valid JSON and cover the package events" do
    for path <- @template_paths do
      decoded =
        path
        |> File.read!()
        |> Jason.decode!()

      assert Map.keys(decoded["hooks"]) |> Enum.sort() == Enum.sort(@expected_events)

      for event <- @expected_events do
        assert is_list(decoded["hooks"][event])
        assert decoded["hooks"][event] != []
      end
    end
  end

  test "hook templates nudge without approving, denying, or continuing turns" do
    for path <- @template_paths do
      template = File.read!(path)

      refute template =~ "permissionDecision"
      refute template =~ "continue\\\":false"
      refute template =~ "continue\":false"
      refute template =~ "claim_work_key"
    end
  end

  test "hook templates avoid raw secret placeholders and raw script associations" do
    for path <- @template_paths do
      template = File.read!(path)

      refute template =~ "sympp_live_"
      refute template =~ "Bearer "
      refute template =~ "GITHUB_TOKEN"
      refute template =~ "LINEAR_TOKEN"
      refute template =~ "MCP_AUTH_TOKEN"
      refute template =~ ".js "
      refute template =~ ".js\""
    end
  end

  test "hook templates launch the helper through explicit shells" do
    posix = File.read!(Path.join(@templates_dir, "hooks.posix.json"))
    windows = File.read!(Path.join(@templates_dir, "hooks.windows.json"))

    assert posix =~ "bash -lc"
    assert posix =~ "candidate in python3 python"
    assert posix =~ "sys.version_info[0] == 3"
    assert posix =~ "done; exit 0"
    assert posix =~ "sympp_hook_nudge.py"
    assert windows =~ "powershell -NoProfile"
    refute windows =~ "pwsh -NoProfile"
    assert windows =~ "sympp_hook_nudge.ps1"
    refute windows =~ "ReadToEnd"
    refute windows =~ "-HookInputText"
    refute windows =~ "$root"
    refute posix =~ "printf %s"
    refute windows =~ "Write-Output '{"
  end

  test "Windows launcher probes common Python commands" do
    launcher = File.read!(@windows_launcher_path)

    assert launcher =~ ~s(Name = "py")
    assert launcher =~ ~s(Name = "python3")
    assert launcher =~ ~s(Name = "python")
    assert launcher =~ "sys.version_info[0] == 3"
    assert launcher =~ ~s(*\\Microsoft\\WindowsApps\\python*.exe)
    assert launcher =~ "exit 0"
    assert launcher =~ "sympp_hook_nudge.py"
    refute launcher =~ "Write-Error"
    refute launcher =~ "Bearer "
    refute launcher =~ "GITHUB_TOKEN"
  end

  test "hook helper emits fixed JSON nudges without echoing sensitive input" do
    python = python_command()
    script = File.read!(@script_path)

    assert script =~ "MESSAGES = {"
    assert script =~ "hook_event_name"
    assert script =~ "MAX_EVENT_SCAN_BYTES"
    assert script =~ "EVENT_PATTERN"
    refute script =~ "json.load"
    refute script =~ "payload.get(\"prompt\")"
    refute script =~ "payload.get(\"tool_input\")"
    refute script =~ "payload.get(\"tool_response\")"
    refute script =~ "payload.get(\"transcript_path\")"

    if is_nil(python) do
      assert script =~ "json.dumps(output"
      assert script =~ "separators=(\",\", \":\")"
      assert script =~ "\"systemMessage\""
      assert script =~ "\"additionalContext\""
      refute script =~ "\"continue\": True, \"systemMessage\""
    else
      exercise_helper_with_python(python)
    end
  end

  defp exercise_helper_with_python(python) do
    for event <- @expected_events do
      stdin =
        Jason.encode!(%{
          hook_event_name: event,
          prompt: "do not echo prompt",
          tool_input: %{"command" => "do not echo command"},
          transcript_path: "do-not-echo-transcript"
        })

      {stdout, 0} = run_helper(python, stdin)
      decoded = Jason.decode!(stdout)
      encoded = Jason.encode!(decoded)

      assert encoded =~ "Symphony++ reminder"
      refute encoded =~ "do not echo prompt"
      refute encoded =~ "do not echo command"
      refute encoded =~ "do-not-echo-transcript"

      if event == "Stop" do
        refute Map.has_key?(decoded, "continue")
      end

      if event == "PostToolUse" do
        output = Map.fetch!(decoded, "hookSpecificOutput")

        assert Map.fetch!(output, "hookEventName") == "PostToolUse"
        assert Map.fetch!(output, "additionalContext") =~ "progress"
        refute Map.has_key?(decoded, "continue")
      end

      refute Map.has_key?(decoded, "decision")
      refute Map.has_key?(decoded, "permissionDecision")
    end

    {stdout, 0} = run_helper(python, ~s({"hook_event_name":"Unknown"}))
    assert stdout == ""
  end

  defp run_helper({executable, prefix_args}, stdin) do
    System.cmd(
      executable,
      prefix_args ++
        [
          "-c",
          "import io, runpy, sys; sys.stdin = io.TextIOWrapper(io.BytesIO(sys.argv[2].encode())); runpy.run_path(sys.argv[1], run_name='__main__')",
          @script_path,
          stdin
        ]
    )
  end

  defp python_command do
    candidates = [{"py", ["-3"]}, {"python3", []}, {"python", []}]

    Enum.find_value(candidates, fn {executable, prefix_args} ->
      path = System.find_executable(executable)

      version_check = "import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)"

      if path && match?({_output, 0}, System.cmd(path, prefix_args ++ ["-c", version_check])) do
        {path, prefix_args}
      end
    end)
  end
end
