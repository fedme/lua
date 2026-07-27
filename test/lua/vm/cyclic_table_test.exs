defmodule Lua.VM.CyclicTableTest do
  @moduledoc """
  Reproduction: cyclic tables crossing the eval boundary recurse forever.

  The standard Lua OOP idiom creates a table that contains itself:

      local T = {}
      T.__index = T
      return T

  Returning such a table from `Lua.eval!/3` never terminates — the
  boundary walk recurses into the cycle, growing memory without bound,
  in both decode modes:

    * `decode: true` — `Lua.VM.Value.decode/2` on the `{:tref, id}`
    * `decode: false` — `Lua.VM.Display.peek_table/3` building the peek

  In a process with `max_heap_size` set (as host applications do for
  sandboxed workers), the VM kills the evaluating process mid-walk.
  These tests run the eval under a 50MB heap cap so the failure is a
  bounded `:killed` exit rather than a hung test run.
  """

  use ExUnit.Case, async: true

  @self_cycle """
  local T = {}
  T.__index = T
  return T
  """

  test "returning a self-referential table terminates (decode: true)" do
    assert eval_capped(@self_cycle, []) != {:died, :killed}
  end

  test "returning a self-referential table terminates (decode: false)" do
    assert eval_capped(@self_cycle, decode: false) != {:died, :killed}
  end

  # Evaluates `code` in a spawned process capped at 50MB heap. Returns
  # {:ok, result} if the eval completes, {:died, reason} if the process
  # exits abnormally (`:killed` = VM max_heap kill from unbounded
  # recursion), or :timeout as a backstop.
  defp eval_capped(code, opts) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(50 * 1024 * 1024, 8),
          kill: true,
          error_logger: false
        })

        send(parent, {:ok, Lua.eval!(Lua.new(), code, opts)})
      end)

    receive do
      {:ok, result} ->
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:died, reason}
    after
      10_000 ->
        Process.exit(pid, :kill)
        :timeout
    end
  end
end
