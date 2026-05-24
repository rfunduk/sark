defmodule Sark.Embedder.Config do
  @moduledoc """
  Parsed `embedder:` block.

      embedder:
        provider: ollama
        model: nomic-embed-text
        dim: 768
        defaults:
          chunk: { size: 1024, overlap: 128 }

  `dim` is the source of truth for the vec0 column width; changing it
  forces a full reindex. Adapters must verify that the configured
  model returns vectors of exactly `dim` floats — mismatch raises.
  """

  @enforce_keys [:provider, :model, :dim]
  defstruct [:provider, :model, :dim, defaults: %{chunk: %{size: 1024, overlap: 128}}]

  @type chunk :: %{size: pos_integer(), overlap: non_neg_integer()}
  @type defaults :: %{chunk: chunk()}
  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          dim: pos_integer(),
          defaults: defaults()
        }

  @spec parse(map() | nil) :: t() | nil
  def parse(nil), do: nil

  def parse(map) when is_map(map) do
    provider = fetch_string!(map, "provider")
    model = fetch_string!(map, "model")
    dim = fetch_pos_integer!(map, "dim")

    defaults = parse_defaults(Map.get(map, "defaults"))

    %__MODULE__{provider: provider, model: model, dim: dim, defaults: defaults}
  end

  def parse(other), do: raise("config: embedder must be a map, got #{inspect(other)}")

  defp parse_defaults(nil), do: %{chunk: %{size: 1024, overlap: 128}}

  defp parse_defaults(map) when is_map(map) do
    %{chunk: parse_chunk(Map.get(map, "chunk"))}
  end

  defp parse_defaults(other),
    do: raise("config: embedder.defaults must be a map, got #{inspect(other)}")

  defp parse_chunk(nil), do: %{size: 1024, overlap: 128}

  defp parse_chunk(map) when is_map(map) do
    size = fetch_pos_integer!(map, "size", "embedder.defaults.chunk")
    overlap = fetch_non_neg_integer!(map, "overlap", "embedder.defaults.chunk")

    if overlap >= size do
      raise "config: embedder.defaults.chunk.overlap must be < size (got #{overlap} >= #{size})"
    end

    %{size: size, overlap: overlap}
  end

  defp parse_chunk(other),
    do: raise("config: embedder.defaults.chunk must be a map, got #{inspect(other)}")

  defp fetch_string!(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) and s != "" -> s
      other -> raise "config: embedder.#{key} must be non-empty string, got #{inspect(other)}"
    end
  end

  defp fetch_pos_integer!(map, key, path \\ "embedder") do
    case Map.get(map, key) do
      n when is_integer(n) and n > 0 -> n
      other -> raise "config: #{path}.#{key} must be positive integer, got #{inspect(other)}"
    end
  end

  defp fetch_non_neg_integer!(map, key, path) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> n
      other -> raise "config: #{path}.#{key} must be non-negative integer, got #{inspect(other)}"
    end
  end
end

defmodule Sark.Embedder do
  @moduledoc """
  Generic embedder client behaviour. Used by the RAG layer (`embed:`
  config on plugin tables) to turn text into fixed-dimension vectors
  for KNN search.

  Instance-wide single provider/model — `Sark.Embedder.Config` is
  parsed from `embedder:` in `config.yml`. Adapters implement the
  `embed/2` callback over a list of texts; sark batches the queue
  drain through a single call where possible.

  Implementations:

    * `Sark.Embedder.Ollama` — calls Ollama's `/api/embed`
  """

  alias Sark.Embedder.Config

  @typedoc "Configured embedder spec (instance-wide)."
  @type spec :: Config.t()

  @typedoc "A single embedding vector (fixed dim per spec)."
  @type vector :: [float()]

  @doc """
  Embed one or more texts. Returns vectors in the same order as the
  input list. Adapters that don't support batching should still take
  a list and call once-per-text internally.
  """
  @callback embed([String.t()], spec()) :: {:ok, [vector()]} | {:error, term()}

  @doc """
  Convenience: embed via the configured provider. Pulls the spec out
  of the current `Sark.Config` and dispatches to the right adapter.
  """
  @spec embed([String.t()]) :: {:ok, [vector()]} | {:error, term()}
  def embed(texts) when is_list(texts) do
    spec = fetch_spec!()
    adapter = adapter_for!(spec.provider)
    adapter.embed(texts, spec)
  end

  @doc """
  Embed a single query text, returning the SQLite-vec little-endian
  float32 binary ready to bind into a `vec0` MATCH parameter. Hits
  `Sark.Embedder.Cache` first; misses call the adapter and cache the
  result. Used by query-time search; the drain doesn't go through
  this path (it batches arbitrary chunk text, which doesn't repeat).
  """
  @spec embed_query(String.t()) :: {:ok, binary()} | {:error, term()}
  def embed_query(text) when is_binary(text) do
    spec = fetch_spec!()
    embed_query(text, spec)
  end

  @doc false
  @spec embed_query(String.t(), Config.t()) :: {:ok, binary()} | {:error, term()}
  def embed_query(text, %Config{} = spec) do
    case Sark.Embedder.Cache.lookup(spec.model, text) do
      {:ok, vec_bin} ->
        {:ok, vec_bin}

      :miss ->
        adapter = adapter_for!(spec.provider)

        case adapter.embed([text], spec) do
          {:ok, [floats | _]} ->
            vec_bin =
              floats
              |> SqliteVec.Float32.new()
              |> SqliteVec.Float32.to_binary()

            :ok = Sark.Embedder.Cache.insert(spec.model, text, vec_bin)
            {:ok, vec_bin}

          {:ok, []} ->
            {:error, :embedder_returned_no_vectors}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Configured embedder spec, or raise if `embedder:` is absent."
  @spec fetch_spec!() :: spec()
  def fetch_spec! do
    # Application env override (tests) wins. Otherwise fall back to
    # the loaded `Sark.Config`'s `embedder:` block.
    case Application.get_env(:sark, :embedder_spec_override) do
      %Config{} = spec ->
        spec

      nil ->
        case Sark.Boot.load_config!() do
          %Sark.Config{embedder: %Config{} = spec} -> spec
          _ -> raise "embedder: not configured in config.yml"
        end
    end
  end

  @doc false
  def adapter_for!(provider) do
    # Application env override exists primarily for tests: register a
    # stub adapter under a chosen provider name without rebuilding
    # provider dispatch.
    overrides = Application.get_env(:sark, :embedder_adapter_overrides, %{})

    case Map.get(overrides, provider) do
      nil -> default_adapter_for!(provider)
      mod -> mod
    end
  end

  defp default_adapter_for!("ollama"), do: Sark.Embedder.Ollama

  defp default_adapter_for!(provider) do
    raise "embedder.provider `#{provider}` not supported yet " <>
            "(supported: ollama)"
  end
end
