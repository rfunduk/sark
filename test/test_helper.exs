setsid_pgid_ok? =
  System.find_executable("setsid") != nil and File.dir?("/proc")

if setsid_pgid_ok? do
  ExUnit.start()
else
  IO.puts(
    IO.ANSI.yellow() <>
      "[test] skipping :setsid_pgid tests (Linux-only — needs setsid + /proc)." <>
      IO.ANSI.reset()
  )

  ExUnit.start(exclude: [:setsid_pgid])
end

# PubSub for write event broadcasts. Tests run with auto_start: false
# so the application supervisor isn't booted.
case Process.whereis(Sark.PubSub) do
  nil -> {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Sark.PubSub)
  _ -> :ok
end
