ExUnit.start()

# PubSub for write event broadcasts. Tests run with auto_start: false
# so the application supervisor isn't booted.
case Process.whereis(Sark.PubSub) do
  nil -> {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Sark.PubSub)
  _ -> :ok
end
