defmodule Sark.MCP.EventBus do
  @moduledoc """
  In-process pub/sub for plugin write events.

  Every successful `write: true` query broadcasts on topic
  `"<plugin>.<query_name>"` with payload:

      {:sark_write, plugin :: String.t(), query :: atom,
       %{params: map, result: term, at: DateTime.t()}}

  L2 workers (M7+) subscribe via `subscribe/1`. Non-durable — subscribers
  offline at broadcast time miss the event. Acceptable for v1.
  """

  @pubsub Sark.PubSub

  @spec topic(String.t(), atom) :: String.t()
  def topic(plugin, query_name) when is_binary(plugin) and is_atom(query_name) do
    "#{plugin}.#{query_name}"
  end

  @spec subscribe(String.t()) :: :ok | {:error, term}
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @spec broadcast_write(String.t(), atom, map, term) :: :ok
  def broadcast_write(plugin, query_name, params, result) do
    payload = %{params: params, result: result, at: DateTime.utc_now()}

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(plugin, query_name),
      {:sark_write, plugin, query_name, payload}
    )
  end
end
