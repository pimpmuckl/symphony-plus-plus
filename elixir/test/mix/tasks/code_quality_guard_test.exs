defmodule Mix.Tasks.CodeQuality.GuardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.CodeQuality.Guard

  setup do
    Mix.Task.reenable("code_quality.guard")
    :ok
  end

  test "passes compact production and test files" do
    in_temp_project(fn ->
      write_source!("lib/sample.ex", """
      defmodule Sample do
        def ok(value), do: value
      end
      """)

      write_source!("test/sample_test.exs", elixir_comment_lines(800))

      output =
        capture_io(fn ->
          assert :ok = Guard.run(["--paths", "lib", "--paths", "test"])
        end)

      assert output =~ "code_quality.guard: checked 2 source file(s); no ratchet regressions"
    end)
  end

  test "uses separate production and test file-size defaults" do
    in_temp_project(fn ->
      write_source!("assets/src/too_big.ts", lines(601))
      write_source!("assets/src/__tests__/large_helper.ts", lines(800))
      write_source!("test/too_big_test.exs", elixir_comment_lines(901))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 2 ratchet violation/, fn ->
            Guard.run(["--paths", "assets/src", "--paths", "test"])
          end
        end)

      assert error_output =~ "assets/src/too_big.ts:1 file file_lines 601 exceeds ratchet 600"
      assert error_output =~ "test/too_big_test.exs:1 file file_lines 901 exceeds ratchet 900"
    end)
  end

  test "includes asset-level test roots in the default scan" do
    in_temp_project(fn ->
      write_source!("assets/__tests__/too_big.ts", lines(901))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run([])
          end
        end)

      assert error_output =~ "assets/__tests__/too_big.ts:1 file file_lines 901 exceeds ratchet 900"
    end)
  end

  test "allows absent optional default roots but fails explicit missing paths" do
    in_temp_project(fn ->
      write_source!("lib/sample.ex", """
      defmodule Sample do
        def ok(value), do: value
      end
      """)

      output =
        capture_io(fn ->
          assert :ok = Guard.run([])
        end)

      assert output =~ "code_quality.guard: checked 1 source file(s); no ratchet regressions"

      assert_raise Mix.Error, ~r/code_quality.guard path does not exist: missing/, fn ->
        Guard.run(["--paths", "missing"])
      end
    end)
  end

  test "allows legacy files to shrink but not grow past measured ratchets" do
    in_temp_project(fn ->
      legacy_path = "lib/symphony_elixir/symphony_plus_plus/work_packages/worktree_lifecycle.ex"

      write_source!(legacy_path, elixir_module_with_comment_lines(736))

      output =
        capture_io(fn ->
          assert :ok = Guard.run(["--paths", legacy_path])
        end)

      assert output =~ "no ratchet regressions"

      write_source!(legacy_path, elixir_module_with_comment_lines(737))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", legacy_path])
          end
        end)

      assert error_output =~ "#{legacy_path}:1 file file_lines 739 exceeds ratchet 738"
    end)
  end

  test "fails named MCP dispatchers with extraction guidance" do
    in_temp_project(fn ->
      dispatcher_path = "lib/symphony_elixir/symphony_plus_plus/mcp/tool_catalog.ex"

      write_source!(dispatcher_path, elixir_module_with_comment_lines(1331))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", dispatcher_path])
          end
        end)

      assert error_output =~ "#{dispatcher_path}:1 MCP dispatcher file file_lines 1333 exceeds MCP dispatcher no-growth ratchet 1332"
      assert error_output =~ "move behavior into focused helper/service modules instead of raising the threshold"
    end)
  end

  test "keeps ordinary legacy ratchets out of the MCP dispatcher policy" do
    in_temp_project(fn ->
      legacy_path = "lib/symphony_elixir/symphony_plus_plus/work_packages/worktree_lifecycle.ex"

      write_source!(legacy_path, elixir_module_with_comment_lines(737))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", legacy_path])
          end
        end)

      assert error_output =~ "#{legacy_path}:1 file file_lines 739 exceeds ratchet 738"
      refute error_output =~ "MCP dispatcher no-growth"
    end)
  end

  test "fails oversized functions in production files" do
    in_temp_project(fn ->
      write_source!("lib/long_function.ex", """
      defmodule LongFunction do
        def run do
      #{indented_lines(121)}
        end
      end
      """)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", "lib"])
          end
        end)

      assert error_output =~ "lib/long_function.ex:2 function run/0 function_lines"
      assert error_output =~ "exceeds ratchet 120"
    end)
  end

  test "measures functions with multiline heads through the body" do
    in_temp_project(fn ->
      write_source!("lib/long_multiline_head.ex", """
      defmodule LongMultilineHead do
        def run(
          first,
          second
        ) do
      #{indented_lines(121)}
        end
      end
      """)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", "lib"])
          end
        end)

      assert error_output =~ "lib/long_multiline_head.ex:2 function run/2 function_lines"
      assert error_output =~ "exceeds ratchet 120"
    end)
  end

  test "aggregates same-name function clauses before enforcing limits" do
    in_temp_project(fn ->
      write_source!("lib/multi_clause.ex", """
      defmodule MultiClause do
        def run(:first) do
      #{indented_lines(80)}
        end

        def run(:second) do
      #{indented_lines(80)}
        end
      end
      """)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", "lib"])
          end
        end)

      assert error_output =~ "lib/multi_clause.ex:2 function run/1 function_lines"
      assert error_output =~ "exceeds ratchet 120"
    end)
  end

  test "does not aggregate same-name functions across sibling modules" do
    in_temp_project(fn ->
      write_source!("lib/sibling_modules.ex", """
      defmodule FirstSibling do
        def run(value) do
      #{indented_lines(70)}
          value
        end
      end

      defmodule SecondSibling do
        def run(value) do
      #{indented_lines(70)}
          value
        end
      end
      """)

      output =
        capture_io(fn ->
          assert :ok = Guard.run(["--paths", "lib"])
        end)

      assert output =~ "code_quality.guard: checked 1 source file(s); no ratchet regressions"
    end)
  end

  test "does not aggregate same-name functions across protocol implementations" do
    in_temp_project(fn ->
      write_source!("lib/protocol_implementations.ex", """
      defprotocol GuardedProtocol do
        def run(value)
      end

      defimpl GuardedProtocol, for: Integer do
        def run(value) do
      #{indented_lines(70)}
          value
        end
      end

      defimpl GuardedProtocol, for: BitString do
        def run(value) do
      #{indented_lines(70)}
          value
        end
      end
      """)

      output =
        capture_io(fn ->
          assert :ok = Guard.run(["--paths", "lib"])
        end)

      assert output =~ "code_quality.guard: checked 1 source file(s); no ratchet regressions"
    end)
  end

  test "fails functions that exceed branch complexity defaults" do
    in_temp_project(fn ->
      write_source!("lib/complex_function.ex", """
      defmodule ComplexFunction do
        def run(value) do
      #{nested_if_lines(21)}
          value
      #{String.duplicate("    end\n", 21)}
        end
      end
      """)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", "lib"])
          end
        end)

      assert error_output =~ "lib/complex_function.ex:2 function run/1 complexity"
      assert error_output =~ "exceeds ratchet 20"
    end)
  end

  test "fails on Elixir parse errors" do
    in_temp_project(fn ->
      write_source!("lib/bad.ex", """
      defmodule Bad do
        def broken(
      """)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/code_quality.guard failed with 1 ratchet violation/, fn ->
            Guard.run(["--paths", "lib"])
          end
        end)

      assert error_output =~ "lib/bad.ex:2 Elixir parse error while measuring quality ratchets"
    end)
  end

  defp in_temp_project(fun) do
    root = Path.join(System.tmp_dir!(), "code-quality-guard-test-#{System.unique_integer([:positive, :monotonic])}")
    original_cwd = File.cwd!()

    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      File.cd!(root, fun)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp write_source!(path, source) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp lines(count) do
    1..count
    |> Enum.map_join("\n", &"// line #{&1}")
    |> Kernel.<>("\n")
  end

  defp elixir_comment_lines(count) do
    1..count
    |> Enum.map_join("\n", &"# line #{&1}")
    |> Kernel.<>("\n")
  end

  defp elixir_module_with_comment_lines(comment_count) do
    comments = Enum.map_join(1..comment_count, "\n", &"# legacy line #{&1}")

    """
    #{comments}
    defmodule LegacyWorktreeLifecycle do
    end
    """
  end

  defp indented_lines(count) do
    Enum.map_join(1..count, "\n", &"    :line_#{&1}")
  end

  defp nested_if_lines(count) do
    Enum.map_join(1..count, "\n", &"    if value == #{&1} do")
  end
end
