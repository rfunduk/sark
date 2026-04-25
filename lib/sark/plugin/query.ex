defmodule Sark.Plugin.Query do
  @moduledoc """
  Parsed canned query loaded from `queries.yml`.

  Holds the compiled SQL (with `:names` rewritten to `?` placeholders),
  the ordered list of parameter names matching those placeholders, the
  declared parameter spec, return shape, and output format. Knows how to
  validate + bind raw param maps from MCP tool calls.
  """

  alias Sark.Plugin.Query.SQL

  @enforce_keys [
    :name,
    :description,
    :returns,
    :write,
    :params,
    :format,
    :raw_sql,
    :compiled_sql,
    :param_order
  ]
  defstruct [
    :name,
    :description,
    :returns,
    :write,
    :params,
    :format,
    :raw_sql,
    :compiled_sql,
    :param_order
  ]

  @type param_type :: :integer | :real | :text | :blob | :null
  @type returns :: :rows | :one_row | :maybe_row | :scalar | :count | :none
  @type format :: :json | :table | :list | {:template, String.t()}

  @type param :: %{
          name: atom,
          type: param_type,
          required: boolean,
          default: term | :none,
          enum: [String.t()] | nil,
          description: String.t() | nil
        }

  @type t :: %__MODULE__{
          name: atom,
          description: String.t(),
          returns: returns,
          write: boolean,
          params: [param],
          format: format,
          raw_sql: String.t(),
          compiled_sql: String.t(),
          param_order: [atom]
        }

  @valid_returns ~w(rows one_row maybe_row scalar count none)a
  @valid_types ~w(integer real text blob null)a

  @doc """
  Parse a single entry from `queries.yml` into a `%Query{}`.

  `name_str` is the YAML map key (a string); `entry` is the value map.
  Raises `ArgumentError` with `where: "queries.yml: <name>"` context on
  any malformed field.
  """
  @spec parse!(String.t(), map) :: t
  def parse!(name_str, entry) when is_binary(name_str) and is_map(entry) do
    name = String.to_atom(name_str)
    where = "queries.yml: #{name_str}"

    description = fetch_string!(entry, "description", where)
    raw_sql = fetch_string!(entry, "sql", where)

    write = Map.get(entry, "write", false)
    unless is_boolean(write), do: bad!(where, "write must be boolean, got #{inspect(write)}")

    returns = parse_returns!(entry, where)
    params = parse_params!(Map.get(entry, "params", %{}), where)
    format = parse_format!(Map.get(entry, "format"), returns, write, where)

    {compiled_sql, param_order} = SQL.compile(raw_sql)
    declared = MapSet.new(params, & &1.name)

    Enum.each(param_order, fn p ->
      unless MapSet.member?(declared, p) do
        bad!(where, "SQL references :#{p} but it is not declared in params")
      end
    end)

    %__MODULE__{
      name: name,
      description: description,
      returns: returns,
      write: write,
      params: params,
      format: format,
      raw_sql: raw_sql,
      compiled_sql: compiled_sql,
      param_order: param_order
    }
  end

  defp parse_returns!(entry, where) do
    case Map.get(entry, "returns") do
      nil ->
        bad!(where, "returns is required")

      str when is_binary(str) ->
        atom = String.to_atom(str)

        if atom in @valid_returns do
          atom
        else
          bad!(where, "returns must be one of #{inspect(@valid_returns)}, got #{inspect(str)}")
        end

      other ->
        bad!(where, "returns must be a string, got #{inspect(other)}")
    end
  end

  defp parse_params!(map, where) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> parse_param!(k, v, where) end)
  end

  defp parse_params!(other, where) do
    bad!(where, "params must be a map, got #{inspect(other)}")
  end

  defp parse_param!(name_str, spec, where) when is_binary(name_str) and is_map(spec) do
    name = String.to_atom(name_str)
    pwhere = "#{where}.params.#{name_str}"

    type_str = Map.get(spec, "type") || bad!(pwhere, "type is required")
    type = String.to_atom(type_str)

    unless type in @valid_types do
      bad!(pwhere, "type must be one of #{inspect(@valid_types)}, got #{inspect(type_str)}")
    end

    required = Map.get(spec, "required", true)
    unless is_boolean(required), do: bad!(pwhere, "required must be boolean")

    default = Map.get(spec, "default", :none)
    enum = Map.get(spec, "enum")

    if enum != nil do
      unless type == :text, do: bad!(pwhere, "enum is only valid for text type")

      unless is_list(enum) and Enum.all?(enum, &is_binary/1),
        do: bad!(pwhere, "enum must be a list of strings")
    end

    description = Map.get(spec, "description")

    %{
      name: name,
      type: type,
      required: required,
      default: default,
      enum: enum,
      description: description
    }
  end

  defp parse_param!(name_str, other, where) do
    bad!(where, "param #{name_str} must be a map, got #{inspect(other)}")
  end

  defp parse_format!(nil, returns, write, _where) do
    default_format(returns, write)
  end

  defp parse_format!(str, _returns, _write, where) when is_binary(str) do
    case str do
      "json" ->
        :json

      "table" ->
        :table

      "list" ->
        :list

      other ->
        bad!(
          where,
          "format must be one of json/table/list/{kind: template}, got #{inspect(other)}"
        )
    end
  end

  defp parse_format!(%{"kind" => "template", "template" => tpl}, _r, _w, _where)
       when is_binary(tpl) do
    {:template, tpl}
  end

  defp parse_format!(other, _r, _w, where) do
    bad!(where, "invalid format: #{inspect(other)}")
  end

  @doc """
  Default renderer rule:
    * `write: true` → `:json`
    * `returns: scalar | count | none` → `:json`
    * reads (rows/one_row/maybe_row) → `:list`
  """
  @spec default_format(returns, boolean) :: format
  def default_format(_returns, true), do: :json
  def default_format(r, false) when r in [:scalar, :count, :none], do: :json
  def default_format(_returns, false), do: :list

  @doc """
  Validate raw params (string-keyed map from MCP) and bind them in the
  positional order required by `compiled_sql`. Returns the bound list or
  a structured validation error.
  """
  @spec validate_and_bind(t, map) ::
          {:ok, [term]} | {:error, {:validation, [%{param: atom, reason: String.t()}]}}
  def validate_and_bind(%__MODULE__{} = q, raw_params) when is_map(raw_params) do
    {coerced, errs} = coerce_each(q.params, raw_params)

    if errs == [] do
      bound = Enum.map(q.param_order, fn name -> Map.fetch!(coerced, name) end)
      {:ok, bound}
    else
      {:error, {:validation, Enum.reverse(errs)}}
    end
  end

  defp coerce_each(specs, raw) do
    Enum.reduce(specs, {%{}, []}, fn spec, {acc, errs} ->
      case fetch_value(spec, raw) do
        {:missing, true} ->
          {acc, [%{param: spec.name, reason: "is required"} | errs]}

        {:missing, false} ->
          {Map.put(acc, spec.name, nil), errs}

        {:ok, raw_v} ->
          case coerce_one(spec, raw_v) do
            {:ok, v} -> {Map.put(acc, spec.name, v), errs}
            {:error, msg} -> {acc, [%{param: spec.name, reason: msg} | errs]}
          end
      end
    end)
  end

  defp fetch_value(spec, raw) do
    key = Atom.to_string(spec.name)

    case Map.fetch(raw, key) do
      {:ok, nil} -> handle_missing(spec)
      {:ok, v} -> {:ok, v}
      :error -> handle_missing(spec)
    end
  end

  defp handle_missing(%{required: true, default: :none}), do: {:missing, true}
  defp handle_missing(%{default: :none}), do: {:missing, false}
  defp handle_missing(%{default: d}), do: {:ok, d}

  defp coerce_one(%{type: :integer}, v) when is_integer(v), do: {:ok, v}

  defp coerce_one(%{type: :integer}, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce_one(%{type: :integer}, _), do: {:error, "must be an integer"}

  defp coerce_one(%{type: :real}, v) when is_number(v), do: {:ok, v * 1.0}

  defp coerce_one(%{type: :real}, v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "must be a number"}
    end
  end

  defp coerce_one(%{type: :real}, _), do: {:error, "must be a number"}

  defp coerce_one(%{type: :text} = spec, v) when is_binary(v) do
    if spec.enum && v not in spec.enum do
      {:error, "must be one of #{inspect(spec.enum)}"}
    else
      {:ok, v}
    end
  end

  defp coerce_one(%{type: :text}, _), do: {:error, "must be a string"}

  defp coerce_one(%{type: :blob}, v) when is_binary(v), do: {:ok, v}
  defp coerce_one(%{type: :blob}, _), do: {:error, "must be a binary"}

  defp coerce_one(%{type: :null}, nil), do: {:ok, nil}
  defp coerce_one(%{type: :null}, _), do: {:error, "must be null"}

  @doc """
  Build the JSON Schema map describing this query's input (per MCP spec).
  Used as `input_schema` in the Phantom tool registration.
  """
  @spec to_json_schema(t) :: map
  def to_json_schema(%__MODULE__{params: params}) do
    properties =
      Map.new(params, fn p ->
        prop = %{type: json_type(p.type)}
        prop = if p.description, do: Map.put(prop, :description, p.description), else: prop
        prop = if p.enum, do: Map.put(prop, :enum, p.enum), else: prop
        {Atom.to_string(p.name), prop}
      end)

    required =
      params
      |> Enum.filter(&(&1.required and &1.default == :none))
      |> Enum.map(&Atom.to_string(&1.name))

    %{
      type: "object",
      properties: properties,
      required: required
    }
  end

  defp json_type(:integer), do: "integer"
  defp json_type(:real), do: "number"
  defp json_type(:text), do: "string"
  defp json_type(:blob), do: "string"
  defp json_type(:null), do: "null"

  defp fetch_string!(map, key, where) do
    case Map.get(map, key) do
      v when is_binary(v) -> v
      nil -> bad!(where, "#{key} is required")
      other -> bad!(where, "#{key} must be a string, got #{inspect(other)}")
    end
  end

  defp bad!(where, msg) do
    raise ArgumentError, "#{where}: #{msg}"
  end
end
