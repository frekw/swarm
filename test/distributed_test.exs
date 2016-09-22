defmodule Swarm.DistributedTests do
  use ExUnit.Case, async: false

  alias Swarm.Nodes

  @moduletag :capture_log
  @moduletag :distributed

  setup_all do
    :rand.seed(:exs64)
    {:ok, _} = :net_kernel.start([:swarm_master, :shortnames])
    :ok
  end

  test "correct redistribution of processes" do
    registry = [broadcast_period: 1000, max_silent_periods: 3, permdown_period: 120_000]

    # start node1
    node1 = Nodes.start(:a, [autocluster: false, debug: true, registry: registry])
    {:ok, _} = :rpc.call(node1, Application, :ensure_all_started, [:swarm])

    # start node2
    node2 = Nodes.start(:b, [autocluster: false, debug: true, registry: registry])
    {:ok, _} = :rpc.call(node2, Application, :ensure_all_started, [:swarm])
    :rpc.call(node2, :net_kernel, :connect_node, [node1])

    Task.start(fn -> :rpc.call(node1, Swarm.Ring, :nodeup, [node2]) end)
    Task.start(fn -> :rpc.call(node2, Swarm.Ring, :nodeup, [node1]) end)

    # give time to warm up
    :timer.sleep(1_000)

    # start 5 processes from node2 to be distributed between node1 and node2
    worker_count = 1
    procs = for n <- 1..worker_count do
      #name = {:"worker#{n}", n}
      name = :"worker#{n}"
      {:ok, pid} = :rpc.call(node2, Swarm, :register_name, [name, MyApp.Worker, :start_link, []])
      {node(pid), name, pid}
    end

    IO.puts "workers started"

    # give time to sync
    :timer.sleep(5_000)

    # pull node2 from the cluster
    #:rpc.call(node2, :erlang, :disconnect_node, [node1])
    Task.start(fn -> :rpc.call(node1, Swarm.Ring, :nodedown, [node2]) end)
    Task.start(fn -> :rpc.call(node2, Swarm.Ring, :nodedown, [node1]) end)

    IO.puts "node2 disconnected"

    # give time to sync
    :timer.sleep(5_000)

    # check to see if the processes were moved as expected
    #procs
    #|> Enum.filter(fn {^node2, _, _} -> true; _ -> false end)
    #|> Enum.map(fn {_, name, _} ->
      #pid = :rpc.call(node1, Swarm, :whereis_name, [name])
      #assert node(pid) == node1
    #end)

    # restore node2 to cluster
    IO.puts "node2 reconnecting"
    Task.start(fn -> :rpc.call(node1, Swarm.Ring, :nodeup, [node2]) end)
    Task.start(fn -> :rpc.call(node2, Swarm.Ring, :nodeup, [node1]) end)
    #:rpc.call(node2, :net_kernel, :connect_node, [node1])
    IO.puts "node2 reconnected"

    # give time to sync
    :timer.sleep(10_000)

    # make sure processes are back in the correct place
    #IO.inspect Enum.filter(procs, fn {^node1, _, _} -> true; _ -> false end)
    misplaced = procs
    |> Enum.filter(fn {^node2, _, _} -> true; _ -> false end)
    |> Enum.filter(fn {_, name, _} ->
      pid = :rpc.call(node1, Swarm, :whereis_name, [name])
      node(pid) != node2
    end)
    IO.inspect {:misplaced, length(misplaced)}

    node1_members = :rpc.call(node1, Swarm, :members, [:swarm_names], :infinity)
    node2_members = :rpc.call(node2, Swarm, :members, [:swarm_names], :infinity)
    n1ms = MapSet.new(node1_members)
    n2ms = MapSet.new(node2_members)
    empty_ms = MapSet.new([])
    IO.inspect {:node1_members, length(node1_members)}
    IO.inspect {:node2_members, length(node2_members)}
    IO.inspect {:union, MapSet.size(MapSet.union(n1ms, n2ms))}
    assert length(node1_members) == worker_count
    assert length(node2_members) == worker_count
    assert ^empty_ms = MapSet.difference(n1ms, n2ms)

    Nodes.stop(node1)
    Nodes.stop(node2)
  end
end