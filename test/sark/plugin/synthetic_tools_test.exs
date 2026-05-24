defmodule Sark.Plugin.SyntheticToolsTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Embed
  alias Sark.Plugin.Spec
  alias Sark.Plugin.SyntheticTools
  alias Sark.Plugin.Tool

  defp spec_with_embed(embed) do
    %Spec{
      name: "p",
      dir: "/tmp/p",
      migrations: [],
      tools: [],
      pipelines: [],
      embed: embed
    }
  end

  test "no embed config → no synthesised tools" do
    assert SyntheticTools.for_spec(spec_with_embed(%{})) == []
  end

  test "one sark_vec_<X> tool per embed table" do
    embed = %{
      "nodes" => %Embed{table: "nodes", fields: ["body"]},
      "docs" => %Embed{table: "docs", fields: ["content"], pk: "uri"}
    }

    tools = SyntheticTools.for_spec(spec_with_embed(embed))
    assert length(tools) == 2

    names = Enum.map(tools, & &1.name) |> Enum.sort()
    assert names == [:sark_vec_docs, :sark_vec_nodes]
  end

  test "synthesised tool has q + limit params w/ embed sibling q_vec" do
    embed = %{"nodes" => %Embed{table: "nodes", fields: ["body"]}}
    [tool] = SyntheticTools.for_spec(spec_with_embed(embed))

    param_names = Enum.map(tool.params, & &1.name) |> Enum.sort()
    assert param_names == [:limit, :q]

    q_param = Enum.find(tool.params, &(&1.name == :q))
    assert q_param.type == :text
    assert q_param.embed == :q_vec

    assert Tool.embed_pairs(tool) == [{:q, :q_vec}]
  end

  test "synthesised SQL references the right vec0/meta tables + pk join" do
    embed = %{"docs" => %Embed{table: "docs", fields: ["content"], pk: "uri"}}
    [tool] = SyntheticTools.for_spec(spec_with_embed(embed))

    [stmt] = tool.statements
    assert stmt.raw_sql =~ "_embeddings_docs ve"
    assert stmt.raw_sql =~ "_embeddings_docs_meta m"
    assert stmt.raw_sql =~ "MATCH :q_vec"
    assert stmt.raw_sql =~ "k = :limit"
    assert stmt.raw_sql =~ "JOIN docs t ON t.uri = r.row_pk"
    assert stmt.raw_sql =~ "ROW_NUMBER() OVER"
  end

  test "synthesised tool returns :results" do
    embed = %{"nodes" => %Embed{table: "nodes", fields: ["body"]}}
    [tool] = SyntheticTools.for_spec(spec_with_embed(embed))
    assert tool.returns == :results
  end

  test "synthesised tool has a non-empty description" do
    embed = %{"nodes" => %Embed{table: "nodes", fields: ["body"]}}
    [tool] = SyntheticTools.for_spec(spec_with_embed(embed))
    assert tool.description =~ "Semantic"
    assert tool.description =~ "nodes"
  end
end
