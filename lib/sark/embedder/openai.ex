defmodule Sark.Embedder.OpenAI do
  @moduledoc """
  OpenAI adapter for `Sark.Embedder`. Hits the `/embeddings` endpoint.

  Provider config:

      providers:
        openai:
          api_key: "${OPENAI_API_KEY}"
          base_url: https://api.openai.com/v1   # optional, this is the default

  Embedder config:

      embedder:
        provider: openai
        model: text-embedding-3-small           # 1536 native
        dim: 1536

  Request:

      POST {base_url}/embeddings
      Authorization: Bearer <api_key>
      { "model": "<model>", "input": [...], "dimensions": <dim>, "encoding_format": "float" }

  `dimensions` is sent unconditionally — `text-embedding-3-*` honour it
  (truncate native dim → configured dim), older models like
  `text-embedding-ada-002` will 400. Use a 3-* model.

  Response data is sorted by `index` defensively before vector extraction
  (the OpenAI docs guarantee order, but the cost of sorting is zero and
  the cost of a silent mis-order would be catastrophic at vec0 layer).
  """

  @behaviour Sark.Embedder

  @default_base_url "https://api.openai.com/v1"
  @timeout_ms 60_000

  @impl true
  def validate_config!(%Sark.Embedder.Config{}, %Sark.Providers{} = providers) do
    case Sark.Providers.get(providers, "openai") do
      nil ->
        raise "embedder.provider = openai but providers.openai is not configured"

      settings ->
        _ = fetch_api_key!(settings)
        :ok
    end
  end

  @impl true
  def embed([], _spec), do: {:ok, []}

  def embed(texts, %Sark.Embedder.Config{} = spec) when is_list(texts) do
    settings = Sark.Providers.fetch!(Sark.Boot.load_config!().providers, "openai")
    api_key = fetch_api_key!(settings)
    url = base_url(settings) <> "/embeddings"

    body =
      %{
        model: spec.model,
        input: texts,
        dimensions: spec.dim,
        encoding_format: "float"
      }
      |> Jason.encode!()

    case post(url, body, api_key) do
      {:ok, %{"data" => data}} when is_list(data) ->
        vectors =
          data
          |> Enum.sort_by(&Map.get(&1, "index", 0))
          |> Enum.map(&Map.get(&1, "embedding"))

        case validate_dim(vectors, spec.dim) do
          :ok -> {:ok, vectors}
          {:error, reason} -> {:error, reason}
        end

      {:ok, other} ->
        {:error, {:bad_response, other}}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_api_key!(%{"api_key" => k}) when is_binary(k) and k != "", do: k
  defp fetch_api_key!(_), do: raise("providers.openai.api_key not set in config.yml")

  defp base_url(%{"base_url" => url}) when is_binary(url) and url != "",
    do: String.trim_trailing(url, "/")

  defp base_url(_), do: @default_base_url

  defp post(url, body, api_key) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"content-type", ~c"application/json"}
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", body}
    http_opts = [timeout: @timeout_ms, connect_timeout: 5_000]
    opts = [body_format: :binary]

    case :httpc.request(:post, request, http_opts, opts) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} when status in 200..299 ->
        Jason.decode(resp_body)

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, {:http_status, status, IO.iodata_to_binary(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_dim([], _dim), do: :ok

  defp validate_dim([first | _], dim) when is_list(first) do
    actual = length(first)

    if actual == dim do
      :ok
    else
      {:error,
       "embedder dim mismatch: configured #{dim}, " <>
         "OpenAI model returned #{actual}-dim vectors"}
    end
  end

  defp validate_dim(_, _), do: {:error, :embeddings_not_a_list}
end
