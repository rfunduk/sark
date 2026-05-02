import Config

config :sark, auto_start: true

config :logger, :default_formatter,
  format: "$time [$level] $message\n",
  metadata: []

# Phantom (streamable HTTP MCP) needs SSE MIME registered at compile time.
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
