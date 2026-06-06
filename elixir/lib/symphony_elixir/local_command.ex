defmodule SymphonyElixir.LocalCommand do
  @moduledoc false

  @spec executable_invocation(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def executable_invocation(executable, args) when is_binary(executable) and is_list(args) do
    if windows_command_script?(executable) do
      {"cmd.exe", ["/d", "/s", "/c", "call", executable | args]}
    else
      {executable, args}
    end
  end

  defp windows_command_script?(executable) do
    match?({:win32, _}, :os.type()) and Path.extname(String.downcase(executable)) in [".bat", ".cmd"]
  end
end
