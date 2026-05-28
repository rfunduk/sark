defmodule Sark.Auth.JSONPathTest do
  use ExUnit.Case, async: true

  alias Sark.Auth.JSONPath

  describe "parse/1" do
    test "splits dotted path into segments" do
      assert JSONPath.parse("realm_access.roles") == ["realm_access", "roles"]
    end

    test "single segment is a one-element list" do
      assert JSONPath.parse("email") == ["email"]
    end

    test "rejects empty string" do
      assert_raise ArgumentError, fn -> JSONPath.parse("") end
    end

    test "rejects non-binary input" do
      assert_raise ArgumentError, fn -> JSONPath.parse(nil) end
    end
  end

  describe "get/2" do
    test "flat key lookup" do
      assert JSONPath.get(%{"email" => "a@b"}, ["email"]) == "a@b"
    end

    test "nested map traversal" do
      claims = %{"realm_access" => %{"roles" => ["admin"]}}
      assert JSONPath.get(claims, ["realm_access", "roles"]) == ["admin"]
    end

    test "missing intermediate key returns nil" do
      assert JSONPath.get(%{"a" => %{}}, ["a", "b", "c"]) == nil
    end

    test "non-map intermediate value returns nil (no list indexing)" do
      assert JSONPath.get(%{"a" => ["x"]}, ["a", "0"]) == nil
    end

    test "nil claims short-circuits" do
      assert JSONPath.get(nil, ["a"]) == nil
    end
  end
end
