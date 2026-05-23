defmodule Sark.Embedder.Ollama do
  @moduledoc """
  Ollama adapter for `Sark.Embedder`. Hits the local Ollama HTTP API
  at `providers.ollama.url` (default `http://localhost:11434`) using
  the `/api/embed` endpoint.

  Request:

      POST /api/embed
      { "model": "<model>", "input": ["text1", "text2", ...] }

  Response:

      { "model": "...", "embeddings": [[...], [...]] }

  No streaming — embeddings come back in one shot. Bulk input is one
  request; the adapter doesn't paginate (Ollama happily takes large
  batches in a single call).

  Dim validation: the first returned vector is checked against
  `spec.dim`. Mismatch raises — usually means the configured model
  doesn't match `dim`, which would silently corrupt the vec0 table.
  """

  @behaviour Sark.Embedder

  @default_url "http://localhost:11434"
  @timeout_ms 60_000

  @impl true
  def embed([], _spec), do: {:ok, []}

  def embed(texts, %Sark.Embedder.Config{} = spec) when is_list(texts) do
    url = base_url() <> "/api/embed"

    body =
      %{
        model: spec.model,
        input: texts
      }
      |> Jason.encode!()

    case post(url, body) do
      {:ok, %{"embeddings" => vectors}} when is_list(vectors) ->
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

  defp base_url do
    case Sark.Providers.get(Sark.Boot.load_config!().providers, "ollama") do
      %{"url" => url} when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @default_url
    end
  end

  defp post(url, body) do
    headers = [{~c"content-type", ~c"application/json"}]
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
         "Ollama model returned #{actual}-dim vectors"}
    end
  end

  defp validate_dim(_, _), do: {:error, :embeddings_not_a_list}
end
