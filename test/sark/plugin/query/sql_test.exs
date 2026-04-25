defmodule Sark.Plugin.Query.SQLTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Query.SQL

  test "rewrites a single named param" do
    {sql, names} = SQL.compile("SELECT * FROM kv WHERE key = :key")
    assert sql == "SELECT * FROM kv WHERE key = ?"
    assert names == [:key]
  end

  test "rewrites multiple distinct names in order" do
    {sql, names} = SQL.compile("SELECT * FROM t WHERE a = :a AND b = :b LIMIT :n")
    assert sql == "SELECT * FROM t WHERE a = ? AND b = ? LIMIT ?"
    assert names == [:a, :b, :n]
  end

  test "repeated name yields one ? per occurrence" do
    {sql, names} = SQL.compile("SELECT :limit, :limit, :limit")
    assert sql == "SELECT ?, ?, ?"
    assert names == [:limit, :limit, :limit]
  end

  test "ignores :name inside single-quoted string" do
    {sql, names} = SQL.compile("SELECT 'hello :world' FROM t WHERE x = :x")
    assert sql == "SELECT 'hello :world' FROM t WHERE x = ?"
    assert names == [:x]
  end

  test "ignores :name inside double-quoted identifier" do
    {sql, names} = SQL.compile("SELECT \":notparam\" FROM t WHERE x = :x")
    assert sql == "SELECT \":notparam\" FROM t WHERE x = ?"
    assert names == [:x]
  end

  test "handles doubled-quote escape in string literal" do
    {sql, names} = SQL.compile("SELECT 'it''s :fine' FROM t WHERE x = :x")
    assert sql == "SELECT 'it''s :fine' FROM t WHERE x = ?"
    assert names == [:x]
  end

  test "ignores :name inside line comment" do
    {sql, names} = SQL.compile("SELECT 1 -- this :commented out\nWHERE x = :x")
    assert sql == "SELECT 1 -- this :commented out\nWHERE x = ?"
    assert names == [:x]
  end

  test "ignores :name inside block comment" do
    {sql, names} = SQL.compile("SELECT 1 /* :nope here */ WHERE x = :x")
    assert sql == "SELECT 1 /* :nope here */ WHERE x = ?"
    assert names == [:x]
  end

  test "::cast skipped, not treated as bind name" do
    {sql, names} = SQL.compile("SELECT a::int, :real FROM t")
    assert sql == "SELECT a::int, ? FROM t"
    assert names == [:real]
  end

  test "lone : with no following identifier left as-is" do
    {sql, names} = SQL.compile("SELECT 'a:b' WHERE x = :x")
    assert sql == "SELECT 'a:b' WHERE x = ?"
    assert names == [:x]
  end

  test "names with digits/underscores after first char" do
    {sql, names} = SQL.compile("WHERE a = :param_1 AND b = :p2")
    assert sql == "WHERE a = ? AND b = ?"
    assert names == [:param_1, :p2]
  end

  test "no params" do
    {sql, names} = SQL.compile("SELECT 1")
    assert sql == "SELECT 1"
    assert names == []
  end

  test "unterminated string is preserved without crashing" do
    {sql, _names} = SQL.compile("SELECT 'oops")
    assert sql =~ "oops"
  end

  test "unterminated block comment is preserved without crashing" do
    {sql, _names} = SQL.compile("SELECT 1 /* never closes")
    assert sql =~ "never closes"
  end
end
