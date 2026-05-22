defmodule SymphonyElixir.SymphonyPlusPlus.RepoIdentity do
  @moduledoc false

  @type identity :: %{
          repo_key: String.t() | nil,
          repo_display: String.t() | nil,
          repo_remote: String.t() | nil,
          repo_aliases: [String.t()]
        }

  @type catalog :: %{optional(String.t()) => identity()}
  @type catalog_opts :: [trusted_remotes: [String.t()]]

  @spec catalog([term()]) :: catalog()
  @spec catalog([term()], catalog_opts()) :: catalog()
  def catalog(repo_values, opts \\ []) do
    infos =
      repo_values
      |> Enum.map(&parse_repo/1)
      |> Enum.reject(&is_nil/1)

    groups = Enum.group_by(infos, & &1.name_key)
    trusted_remote_keys = trusted_remote_keys(opts)

    Map.new(infos, fn info ->
      {info.raw, identity(info, Map.fetch!(groups, info.name_key), trusted_remote_keys)}
    end)
  end

  @spec fields(catalog(), term()) :: identity()
  def fields(catalog, raw_repo) when is_map(catalog) and is_binary(raw_repo) do
    Map.get(catalog, raw_repo) || fallback_fields(raw_repo)
  end

  def fields(_catalog, _raw_repo), do: empty_identity()

  defp fallback_fields(raw_repo) do
    [raw_repo]
    |> catalog()
    |> Map.get(raw_repo, empty_identity())
  end

  defp identity(info, group, trusted_remote_keys) do
    collapsed_group? = collapsed_group?(group, trusted_remote_keys)
    identity_infos = identity_infos(group, info, collapsed_group?)
    remote = identity_infos |> Enum.find(&(&1.kind == :remote)) |> remote_display()

    %{
      repo_key: repo_key(info, collapsed_group?),
      repo_display: repo_display(info, group, collapsed_group?),
      repo_remote: remote,
      repo_aliases: aliases(identity_infos)
    }
  end

  defp repo_key(info, false) when info.kind == :remote, do: info.full_key
  defp repo_key(info, _collapsed_group?), do: info.name_key

  defp repo_display(info, _group, false) when info.kind == :remote, do: info.full_display

  defp repo_display(_info, group, _collapsed_group?) do
    group
    |> Enum.find(&(&1.kind == :bare))
    |> case do
      nil -> group |> hd() |> Map.fetch!(:name_display)
      bare -> bare.name_display
    end
  end

  defp identity_infos(group, _info, true), do: group

  defp identity_infos(group, info, false) when info.kind == :remote do
    Enum.filter(group, &(&1.full_key == info.full_key))
  end

  defp identity_infos(group, _info, false), do: Enum.reject(group, &(&1.kind == :remote))

  defp collapsed_group?(group, trusted_remote_keys) do
    remote_keys =
      group
      |> Enum.filter(&(&1.kind == :remote))
      |> Enum.map(& &1.full_key)
      |> Enum.uniq()

    cond do
      remote_keys == [] -> true
      length(remote_keys) > 1 -> false
      bare_alias?(group) -> MapSet.member?(trusted_remote_keys, hd(remote_keys))
      true -> false
    end
  end

  defp bare_alias?(group), do: Enum.any?(group, &(&1.kind == :bare))

  defp trusted_remote_keys(opts) do
    opts
    |> Keyword.get(:trusted_remotes, [])
    |> List.wrap()
    |> Enum.map(&trusted_remote_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp trusted_remote_key(remote) when is_binary(remote) do
    case parse_repo(remote) do
      %{kind: :remote, full_key: full_key} -> full_key
      _other -> nil
    end
  end

  defp trusted_remote_key(_remote), do: nil

  defp aliases(infos) do
    infos
    |> Enum.map(& &1.alias)
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end

  defp remote_display(nil), do: nil
  defp remote_display(info), do: info.full_display

  defp parse_repo(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> normalized_repo_path()
    |> do_parse_repo(raw)
  end

  defp parse_repo(_raw), do: nil

  defp do_parse_repo("", _raw), do: nil

  defp do_parse_repo(repo_path, raw) do
    parts =
      repo_path
      |> trim_git_suffix()
      |> String.trim("/")
      |> String.split("/", trim: true)

    case parts do
      [name] ->
        repo_info(raw, :bare, name, name)

      [owner, name] ->
        repo_info(raw, :remote, "#{owner}/#{name}", name)

      _parts ->
        repo_info(raw, :opaque, repo_path, repo_path)
    end
  end

  defp repo_info(raw, kind, full_display, name_display) do
    %{
      raw: raw,
      kind: kind,
      name_key: key(name_display),
      name_display: name_display,
      full_key: key(full_display),
      full_display: full_display,
      alias: full_display
    }
  end

  defp normalized_repo_path(repo) do
    case github_ssh_path(repo) do
      nil -> github_uri_path(repo)
      path -> path
    end
  end

  defp github_ssh_path(repo) do
    case Regex.run(~r/\Agit@github\.com:(?<repo>[^?#]+)\z/i, repo, capture: :all_names) do
      [path] -> path
      nil -> nil
    end
  end

  defp github_uri_path(repo) do
    uri = URI.parse(repo)
    github_host? = String.downcase(uri.host || "") == "github.com"
    github_scheme? = uri.scheme in ["http", "https"] or (uri.scheme == "ssh" and uri.userinfo in [nil, "git"])

    if github_host? and github_scheme? and is_binary(uri.path) do
      String.trim_leading(uri.path, "/")
    else
      repo
    end
  rescue
    _error in URI.Error -> repo
  end

  defp trim_git_suffix(repo) do
    if String.ends_with?(repo, ".git") do
      String.replace_suffix(repo, ".git", "")
    else
      repo
    end
  end

  defp key(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp empty_identity do
    %{
      repo_key: nil,
      repo_display: nil,
      repo_remote: nil,
      repo_aliases: []
    }
  end
end
