defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [
      :path,
      :metadata_stamp,
      :verified_metadata_stamp,
      :content_hash,
      :workflow,
      :poll_interval_ms,
      :file_ops
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current)

      _ ->
        Workflow.load()
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case Workflow.load() do
          {:ok, _workflow} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(opts) do
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    file_ops = Keyword.get(opts, :file_ops, default_file_ops())

    case load_state(Workflow.workflow_file_path(), file_ops) do
      {:ok, state} ->
        schedule_poll(poll_interval_ms)
        {:ok, %{state | poll_interval_ms: poll_interval_ms, file_ops: file_ops}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case force_reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  defp force_reload_state(%State{} = state) do
    Workflow.workflow_file_path()
    |> reload_path(state)
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    poll_interval_ms = state.poll_interval_ms || @poll_interval_ms
    schedule_poll(poll_interval_ms)

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll(poll_interval_ms) do
    Process.send_after(self(), :poll, poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path, state.file_ops) do
      {:ok, new_state} ->
        {:ok, %{new_state | poll_interval_ms: state.poll_interval_ms, file_ops: state.file_ops}}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_metadata_stamp(path, state.file_ops) do
      {:ok, metadata_stamp} when metadata_stamp == state.metadata_stamp ->
        reload_verified_metadata(path, metadata_stamp, state)

      {:ok, metadata_stamp} ->
        reload_changed_metadata(path, metadata_stamp, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_verified_metadata(path, metadata_stamp, state) do
    if state.verified_metadata_stamp == metadata_stamp do
      {:ok, state}
    else
      reload_changed_metadata(path, metadata_stamp, state)
    end
  end

  defp reload_changed_metadata(path, metadata_stamp, state) do
    case current_content_hash(path, state.file_ops) do
      {:ok, content_hash} when content_hash == state.content_hash ->
        {:ok,
         %{
           state
           | metadata_stamp: metadata_stamp,
             verified_metadata_stamp: verified_metadata_stamp(metadata_stamp)
         }}

      {:ok, _content_hash} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path, file_ops) do
    with {:ok, content} <- read_workflow_content(path, file_ops),
         {:ok, workflow} <- Workflow.load_content(content),
         {:ok, metadata_stamp} <- current_metadata_stamp(path, file_ops) do
      {:ok,
       %State{
         path: path,
         metadata_stamp: metadata_stamp,
         verified_metadata_stamp: verified_metadata_stamp(metadata_stamp),
         content_hash: hash_content(content),
         workflow: workflow
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_metadata_stamp(path, file_ops) when is_binary(path) do
    time_unit = :posix

    case file_stat(file_ops, path, time: time_unit) do
      {:ok, stat} -> {:ok, {time_unit, stat.mtime, stat.ctime, stat.size}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_content_hash(path, file_ops) when is_binary(path) do
    with {:ok, content} <- file_read(file_ops, path) do
      {:ok, hash_content(content)}
    end
  end

  defp read_workflow_content(path, file_ops) do
    case file_read(file_ops, path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp hash_content(content), do: :erlang.phash2(content)

  defp verified_metadata_stamp({:posix, mtime, ctime, _size} = metadata_stamp) do
    current_second = System.system_time(:second)

    if is_integer(mtime) and is_integer(ctime) and mtime < current_second and ctime < current_second do
      metadata_stamp
    end
  end

  defp default_file_ops do
    %{stat: &File.stat/2, read: &File.read/1}
  end

  defp file_stat(%{stat: stat}, path, opts) when is_function(stat, 2), do: stat.(path, opts)

  defp file_read(%{read: read}, path) when is_function(read, 1), do: read.(path)

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end
end
