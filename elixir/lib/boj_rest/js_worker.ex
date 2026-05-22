# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule BojRest.JsWorker do
  @moduledoc """
  GenServer wrapping one persistent Deno pool-worker process.

  Communication: newline-delimited JSON over the process's stdin/stdout.
  Requests are processed sequentially on the Deno side (one `await` at a time),
  but multiple callers can queue requests concurrently — replies are matched by
  the `id` field in each response.

  When the underlying Deno process exits unexpectedly all pending callers
  receive `{:error, %{classification: :worker_crashed, ...}}` and the GenServer
  stops so the pool Supervisor can restart it with a fresh Deno process.
  """
  use GenServer
  require Logger

  # Budget slightly above the JsInvoker timeout so the caller sees a clean
  # timeout error rather than a GenServer call timeout exception.
  @timeout_ms 30_000
  @call_timeout_ms @timeout_ms + 5_000

  defstruct [:port, :pending, :buffer, :id_counter]

  # ── public API ───────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc """
  Invoke `tool_name` on the cartridge at `mod_js_path` via the persistent worker.

  `extra_env` is forwarded inside the JSON request and applied/cleared by the
  pool worker per invocation — safe because the worker processes requests one
  at a time.
  """
  @spec invoke(GenServer.server(), String.t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, map()}
  def invoke(server, mod_js_path, tool_name, args, extra_env \\ %{}) do
    GenServer.call(server, {:invoke, mod_js_path, tool_name, args, extra_env}, @call_timeout_ms)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    deno = Keyword.fetch!(opts, :deno_path)
    runner = Keyword.fetch!(opts, :runner_path)

    port =
      Port.open({:spawn_executable, deno}, [
        :binary,
        :exit_status,
        {:args, ["run", "--allow-net", "--allow-env", "--allow-read", runner]}
      ])

    Logger.debug("JsWorker started", deno: deno, runner: runner)
    {:ok, %__MODULE__{port: port, pending: %{}, buffer: "", id_counter: 0}}
  end

  @impl true
  def handle_call({:invoke, mod_js_path, tool_name, args, extra_env}, from, state) do
    id = Integer.to_string(state.id_counter)

    request =
      Jason.encode!(%{
        id: id,
        mod: mod_js_path,
        tool: tool_name,
        args: args,
        env: extra_env
      })

    Port.command(state.port, request <> "\n")
    timer = Process.send_after(self(), {:timeout, id}, @timeout_ms)
    pending = Map.put(state.pending, id, {from, timer})
    {:noreply, %{state | pending: pending, id_counter: state.id_counter + 1}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    full = state.buffer <> data
    {lines, rest} = split_lines(full)
    new_state = Enum.reduce(lines, state, &dispatch_response/2)
    {:noreply, %{new_state | buffer: rest}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Deno pool worker exited unexpectedly", exit_code: code)

    Enum.each(state.pending, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, %{classification: :worker_crashed, body: "Deno worker exited with code #{code}"}})
    end)

    {:stop, :normal, %{state | pending: %{}}}
  end

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, %{classification: :timeout, body: "JS invocation timed out after #{@timeout_ms}ms"}})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # ── private helpers ────────────────────────────────────────────────────────

  # Split accumulated bytes at newlines; return {complete_lines, remainder}.
  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.slice(parts, 0, length(parts) - 1) |> Enum.reject(&(&1 == "")),
     List.last(parts) || ""}
  end

  defp dispatch_response(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "status" => status, "data" => data}} ->
        case Map.pop(state.pending, id) do
          {{from, timer}, pending} ->
            Process.cancel_timer(timer)
            result = if status in 200..299, do: {:ok, data}, else: {:error, %{classification: :js_error, body: data, status: status}}
            GenServer.reply(from, result)
            %{state | pending: pending}

          {nil, _} ->
            Logger.warning("JsWorker: unexpected response id", id: id)
            state
        end

      _ ->
        Logger.warning("JsWorker: could not decode response line", line: line)
        state
    end
  end
end
