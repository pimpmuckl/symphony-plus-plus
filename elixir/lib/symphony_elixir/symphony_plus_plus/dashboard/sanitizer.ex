defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @spec redacted_json(term()) :: term()
  def redacted_json(value) do
    value
    |> Redactor.redact()
    |> Redactor.json_safe()
    |> redact_url_values()
  end

  defp redact_url_values(%{} = value) do
    Map.new(value, fn {key, field_value} ->
      {key, redacted_json_field(key, field_value)}
    end)
  end

  defp redact_url_values(values) when is_list(values), do: Enum.map(values, &redacted_json_value/1)
  defp redact_url_values(value), do: redacted_json_value(value)

  defp redacted_json_value(%{} = value) do
    Map.new(value, fn {key, field_value} ->
      {key, redacted_json_field(key, field_value)}
    end)
  end

  defp redacted_json_value(values) when is_list(values), do: Enum.map(values, &redacted_json_value/1)
  defp redacted_json_value(value) when is_binary(value), do: redacted_text(value)
  defp redacted_json_value(value), do: value

  defp redacted_json_field(key, value) do
    cond do
      sensitive_key?(key) -> "[REDACTED]"
      url_key?(key) -> redact_url_field(value)
      true -> redacted_json_value(value)
    end
  end

  defp sensitive_key?(key) when is_binary(key) do
    key = String.downcase(key)

    String.contains?(key, "secret") or String.contains?(key, "token") or String.contains?(key, "hash")
  end

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()
  defp sensitive_key?(_key), do: false

  defp url_key?(key) when is_binary(key), do: String.downcase(key) in ["href", "link", "links", "uri", "url", "urls"]
  defp url_key?(_key), do: false

  defp redact_url_field(%{} = value), do: Map.new(value, fn {key, field_value} -> {key, redact_url_field(field_value)} end)
  defp redact_url_field(values) when is_list(values), do: Enum.map(values, &redact_url_field/1)
  defp redact_url_field(value), do: redacted_uri(value)

  @spec redacted_text(term()) :: term()
  def redacted_text(nil), do: nil

  def redacted_text(value) when is_binary(value) do
    redacted = redact_signed_url_text(value)

    cond do
      redacted != value -> "[REDACTED]"
      sensitive_text?(value) -> "[REDACTED]"
      true -> value
    end
  end

  def redacted_text(value), do: value

  defp sensitive_text?(value) do
    String.match?(
      value,
      ~r/(bearer\s+\S+|wk_[A-Za-z0-9_-]{43,}|raw[_-]?secret[_-][A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,})/i
    )
  end

  @spec redacted_uri(term()) :: term()
  def redacted_uri(nil), do: nil

  def redacted_uri(value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      is_binary(uri.query) and uri.query != "" -> "[REDACTED]"
      sensitive_text?(value) -> "[REDACTED]"
      true -> value
    end
  end

  def redacted_uri(value), do: value

  defp redact_signed_url_text(value) do
    Regex.replace(~r/https?:\/\/[^\s<>"']+\?[^\s<>"']*/i, value, "[REDACTED_URL]")
  end

  @spec timestamp_sort_value(term()) :: integer()
  def timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  def timestamp_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> -1
    end
  end

  def timestamp_sort_value(nil), do: -1

  @spec timestamp(term()) :: String.t() | nil
  def timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def timestamp(nil), do: nil
end
