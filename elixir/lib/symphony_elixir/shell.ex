defmodule SymphonyElixir.Shell do
  @moduledoc false

  @spec find_posix_shell([String.t()]) :: String.t() | nil
  def find_posix_shell(names \\ ["sh", "bash"]) when is_list(names) do
    names
    |> Enum.flat_map(&shell_candidates/1)
    |> Enum.find(&executable_file?/1)
  end

  defp shell_candidates(name) do
    known_windows_shells(name) ++ system_shell(name)
  end

  defp known_windows_shells("bash") do
    windows_program_files()
    |> Enum.map(&Path.join([&1, "Git", "bin", "bash.exe"]))
  end

  defp known_windows_shells("sh") do
    windows_program_files()
    |> Enum.map(&Path.join([&1, "Git", "usr", "bin", "sh.exe"]))
  end

  defp known_windows_shells(_name), do: []

  defp windows_program_files do
    if match?({:win32, _}, :os.type()) do
      ["ProgramFiles", "ProgramFiles(x86)"]
      |> Enum.map(&System.get_env/1)
      |> Enum.filter(&is_binary/1)
    else
      []
    end
  end

  defp system_shell(name) do
    case System.find_executable(name) do
      nil -> []
      path -> [path]
    end
  end

  defp executable_file?(path), do: is_binary(path) and native_executable?(path) and File.exists?(path)

  defp native_executable?(path) do
    not match?({:win32, _name}, :os.type()) or Path.extname(String.downcase(path)) not in [".bat", ".cmd"]
  end
end
