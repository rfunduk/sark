defmodule Sark.Providers do
  @moduledoc """
  Parses the top-level `providers:` block of `config.yml`.

  Providers are external-service credentials and connection settings,
  consumed by LLM and embedder adapters. The block is a map of
  provider-name → settings:

      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
        ollama:
          url: http://localhost:11434
        openai:
          api_key: "${OPENAI_API_KEY}"
          base_url: https://api.openai.com/v1
        voyage:
          api_key: "${VOYAGE_API_KEY}"
        bumblebee:
          # no fields — runs in-process

  Each adapter pulls its own settings out via `fetch/2`. Sark itself
  does not validate provider-specific shape here — adapters are
  responsible for raising a clear error if their required keys are
  missing at use time. This keeps `providers:` open to community
  adapters without changing the config parser.
  """

  defstruct entries: %{}

  @type t :: %__MODULE__{entries: %{String.t() => map()}}

  @spec parse(map() | nil) :: t()
  def parse(nil), do: %__MODULE__{}
  def parse(map) when map == %{}, do: %__MODULE__{}

  def parse(map) when is_map(map) do
    entries =
      Map.new(map, fn
        {name, settings} when is_binary(name) and is_map(settings) ->
          {name, settings}

        {name, nil} when is_binary(name) ->
          {name, %{}}

        {name, other} ->
          raise "config: providers.#{name} must be a map, got #{inspect(other)}"
      end)

    %__MODULE__{entries: entries}
  end

  def parse(other), do: raise("config: providers must be a map, got #{inspect(other)}")

  @doc """
  Fetch a provider's settings map. Raises if the provider isn't
  configured — adapters use this at first call.
  """
  @spec fetch!(t(), String.t()) :: map()
  def fetch!(%__MODULE__{entries: entries}, name) when is_binary(name) do
    case Map.fetch(entries, name) do
      {:ok, settings} ->
        settings

      :error ->
        raise "providers.#{name} not configured in config.yml"
    end
  end

  @doc "Returns provider settings or `nil` if absent."
  @spec get(t(), String.t()) :: map() | nil
  def get(%__MODULE__{entries: entries}, name), do: Map.get(entries, name)

  @doc "List configured provider names."
  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{entries: entries}), do: Map.keys(entries)
end
