defmodule SymphonyElixir.LocalCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LocalCommand

  test "wraps Windows command scripts before spawning local commands" do
    if windows?() do
      assert {"cmd.exe", ["/d", "/s", "/c", "call", "C:/Program Files/nodejs/npm.cmd", "run", "build"]} =
               LocalCommand.executable_invocation("C:/Program Files/nodejs/npm.cmd", ["run", "build"])

      script_dir = Path.join(System.tmp_dir!(), "sympp local command #{System.unique_integer([:positive])}")
      script_path = Path.join(script_dir, "echo args.cmd")

      try do
        File.mkdir_p!(script_dir)
        File.write!(script_path, "@echo off\r\necho first=%~1\r\necho second=%~2\r\n")

        {executable, args} = LocalCommand.executable_invocation(script_path, ["run", "build"])
        assert {output, 0} = System.cmd(executable, args, stderr_to_stdout: true)
        assert String.split(String.trim(output), ~r/\R/) == ["first=run", "second=build"]
      after
        File.rm_rf!(script_dir)
      end
    else
      assert {"npm", ["run", "build"]} = LocalCommand.executable_invocation("npm", ["run", "build"])
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
