defmodule Sark.Plugin.Query do
  @moduledoc """
  Parsed canned query loaded from `queries.yml`.

  A query may have one or more SQL statements. `sql:` accepts a string
  (one statement) or a list of strings (statements run in order, in a
  single transaction for writes / in sequence on the read pool for
  reads). All statements share the declared `params:` and reference
  them by `:name`. The response is the last statement's result.
  """

  alias Sark.Plugin.Query.SQL

  @enforce_keys [
    :name,
    :description,
    :returns,
    :write,
    :params,
    :format,
    :statements
  ]
  defstruct [
    :name,
    :description,
    :returns,
    :write,
    :params,
    :format,
    :statements,
    internal: false
  ]

  @type param_type :: :integer | :real | :text | :blob | :boolean
  @type returns :: :results | :scalar | :count | :none
  @type format :: :json | :table | :list | {:template, String.t()}

  @type param :: %{
          name: atom,
          type: param_type,
          required: boolean,
          default: term | :none,
          enum: [String.t()] | nil,
          description: String.t() | nil
        }

  @type statement :: %{
          raw_sql: String.t(),
          compiled_sql: String.t(),
          param_order: [atom]
        }

  @type t :: %__MODULE__{
          name: atom,
          description: String.t(),
          returns: returns,
          write: boolean,
          params: [param],
          format: format,
          statements: [statement],
          internal: boolean
        }

  @valid_returns ~w(results scalar count none)a
  @valid_types ~w(integer real text blob boolean array object)a

  @doc """
  Parse a single entry from `queries.yml` into a `%Query{}`.
  """
  @spec parse!(String.t(), map) :: t
  def parse!(name_str, entry) when is_binary(name_str) and is_map(entry) do
    name = String.to_atom(name_str)
    where = "queries.yml: #{name_str}"

    description = fetch_string!(entry, "description", where)
    raw_sqls = parse_sql!(Map.get(entry, "sql"), where)

    write = Map.get(entry, "write", false)
    unless is_boolean(write), do: bad!(where, "write must be boolean, got #{inspect(write)}")

    internal = Map.get(entry, "internal", false)

    unless is_boolean(internal),
      do: bad!(where, "internal must be boolean, got #{inspect(internal)}")

    returns = parse_returns!(entry, where)
    params = parse_params!(Map.get(entry, "params", %{}), where)
    format = parse_format!(Map.get(entry, "format"), returns, write, where)

    declared = MapSet.new(params, & &1.name)

    statements =
      Enum.map(raw_sqls, fn raw ->
        {compiled, order} = SQL.compile(raw)

        Enum.each(order, fn p ->
          unless MapSet.member?(declared, p) do
            bad!(where, "SQL references :#{p} but it is not declared in params")
          end
        end)

        %{raw_sql: raw, compiled_sql: compiled, param_order: order}
      end)

    %__MODULE__{
      name: name,
      description: description,
      returns: returns,
      write: write,
      internal: internal,
      params: params,
      format: format,
      statements: statements
    }
  end

  defp parse_sql!(nil, where), do: bad!(where, "sql is required")

  defp parse_sql!(s, _where) when is_binary(s), do: [s]

  defp parse_sql!(list, where) when is_list(list) do
    if list == [] do
      bad!(where, "sql list must not be empty")
    end

    Enum.each(list, fn s ->
      unless is_binary(s),
        do: bad!(where, "every sql list entry must be a string, got #{inspect(s)}")
    end)

    list
  end

  defp parse_sql!(other, where) do
    bad!(where, "sql must be a string or list of strings, got #{inspect(other)}")
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
    base = parse_value_spec!(spec, pwhere)
    Map.put(base, :name, name)
  end

  defp parse_param!(name_str, other, where) do
    bad!(where, "param #{name_str} must be a map, got #{inspect(other)}")
  end

  # Parse a value spec without `name` — used for top-level params (named
  # via parse_param!) and for `items` (anonymous) and nested object
  # `properties` (named, via parse_param! recursion).
  defp parse_value_spec!(spec, where) when is_map(spec) do
    type_str = Map.get(spec, "type") || bad!(where, "type is required")
    type = String.to_atom(type_str)

    unless type in @valid_types do
      bad!(where, "type must be one of #{inspect(@valid_types)}, got #{inspect(type_str)}")
    end

    required = Map.get(spec, "required", true)
    unless is_boolean(required), do: bad!(where, "required must be boolean")

    default = Map.get(spec, "default", :none)

    if default != :none and type in [:array, :object] do
      bad!(where, "default not supported for #{type} type yet")
    end

    enum = Map.get(spec, "enum")

    if enum != nil do
      unless type == :text, do: bad!(where, "enum is only valid for text type")

      unless is_list(enum) and Enum.all?(enum, &is_binary/1),
        do: bad!(where, "enum must be a list of strings")
    end

    description = Map.get(spec, "description")

    base = %{
      type: type,
      required: required,
      default: default,
      enum: enum,
      description: description
    }

    case type do
      :array ->
        items_raw = Map.get(spec, "items") || bad!(where, "array type requires items spec")
        items = parse_value_spec!(items_raw, "#{where}.items")
        Map.put(base, :items, items)

      :object ->
        props_raw =
          Map.get(spec, "properties") || bad!(where, "object type requires properties spec")

        unless is_map(props_raw), do: bad!(where, "properties must be a map")

        properties =
          props_raw
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {k, v} -> parse_param!(k, v, "#{where}.properties") end)

        Map.put(base, :properties, properties)

      _ ->
        base
    end
  end

  defp parse_value_spec!(other, where) do
    bad!(where, "spec must be a map, got #{inspect(other)}")
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
    * `returns: results` → `:list`
  """
  @spec default_format(returns, boolean) :: format
  def default_format(_returns, true), do: :json
  def default_format(r, false) when r in [:scalar, :count, :none], do: :json
  def default_format(:results, false), do: :list

  @doc """
  Validate raw params (string-keyed map from MCP) and bind them in the
  positional order required by each statement. Returns a list of bind
  lists (one per statement) or a structured validation error.
  """
  @spec validate_and_bind(t, map) ::
          {:ok, [[term]]} | {:error, {:validation, [%{param: atom, reason: String.t()}]}}
  def validate_and_bind(%__MODULE__{} = q, raw_params) when is_map(raw_params) do
    {coerced, errs} = coerce_each(q.params, raw_params)

    if errs == [] do
      binds =
        Enum.map(q.statements, fn s ->
          Enum.map(s.param_order, fn name -> Map.fetch!(coerced, name) end)
        end)

      {:ok, binds}
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

  # SQLite has no native bool — bind 1 / 0. Accept JSON true/false only;
  # don't quietly coerce 1/0/"true"/"yes" to keep agent contracts crisp.
  defp coerce_one(%{type: :boolean}, true), do: {:ok, 1}
  defp coerce_one(%{type: :boolean}, false), do: {:ok, 0}
  defp coerce_one(%{type: :boolean}, _), do: {:error, "must be true or false"}

  # Composite types validate + normalize to native Elixir terms, then
  # encode to JSON TEXT for the SQLite bind. Plugin SQL uses
  # json_each / json_extract to fan out.
  defp coerce_one(%{type: :array} = spec, list) when is_list(list) do
    case normalize_value(spec, list) do
      {:ok, native} -> {:ok, Jason.encode!(native)}
      err -> err
    end
  end

  defp coerce_one(%{type: :array}, _), do: {:error, "must be an array"}

  defp coerce_one(%{type: :object} = spec, map) when is_map(map) do
    case normalize_value(spec, map) do
      {:ok, native} -> {:ok, Jason.encode!(native)}
      err -> err
    end
  end

  defp coerce_one(%{type: :object}, _), do: {:error, "must be an object"}

  # normalize_value/2 returns native Elixir terms (no JSON encoding).
  # Used recursively to build the structure that the outer coerce_one
  # then JSON-encodes once.
  defp normalize_value(%{type: t}, v)
       when t in [:integer, :real, :text, :blob, :boolean] do
    coerce_scalar(t, v)
  end

  defp normalize_value(%{type: :array, items: items_spec}, list) when is_list(list) do
    normalize_array(list, items_spec, 0, [])
  end

  defp normalize_value(%{type: :array}, _), do: {:error, "must be an array"}

  defp normalize_value(%{type: :object, properties: props}, map) when is_map(map) do
    normalize_object(map, props)
  end

  defp normalize_value(%{type: :object}, _), do: {:error, "must be an object"}

  defp coerce_scalar(:integer, v) when is_integer(v), do: {:ok, v}

  defp coerce_scalar(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce_scalar(:integer, _), do: {:error, "must be an integer"}

  defp coerce_scalar(:real, v) when is_number(v), do: {:ok, v * 1.0}

  defp coerce_scalar(:real, v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "must be a number"}
    end
  end

  defp coerce_scalar(:real, _), do: {:error, "must be a number"}

  defp coerce_scalar(:text, v) when is_binary(v), do: {:ok, v}
  defp coerce_scalar(:text, _), do: {:error, "must be a string"}

  defp coerce_scalar(:blob, v) when is_binary(v), do: {:ok, v}
  defp coerce_scalar(:blob, _), do: {:error, "must be a binary"}

  defp coerce_scalar(:boolean, true), do: {:ok, 1}
  defp coerce_scalar(:boolean, false), do: {:ok, 0}
  defp coerce_scalar(:boolean, _), do: {:error, "must be true or false"}

  defp normalize_array([], _items_spec, _idx, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_array([item | rest], items_spec, idx, acc) do
    case validate_with_enum(items_spec, item) do
      {:ok, v} -> normalize_array(rest, items_spec, idx + 1, [v | acc])
      {:error, "." <> _ = msg} -> {:error, "[#{idx}]#{msg}"}
      {:error, msg} -> {:error, "[#{idx}] #{msg}"}
    end
  end

  defp normalize_object(map, props) do
    Enum.reduce_while(props, {:ok, %{}}, fn p, {:ok, acc} ->
      key = Atom.to_string(p.name)

      case Map.fetch(map, key) do
        :error ->
          if p.required and p.default == :none do
            {:halt, {:error, ".#{p.name} is required"}}
          else
            default =
              case p.default do
                :none -> nil
                d -> d
              end

            {:cont, {:ok, Map.put(acc, key, default)}}
          end

        {:ok, nil} ->
          if p.required and p.default == :none do
            {:halt, {:error, ".#{p.name} is required"}}
          else
            {:cont, {:ok, Map.put(acc, key, nil)}}
          end

        {:ok, raw_v} ->
          case validate_with_enum(p, raw_v) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, key, v)}}
            {:error, msg} -> {:halt, {:error, ".#{p.name} #{msg}"}}
          end
      end
    end)
  end

  # Like normalize_value but applies enum check (only relevant for text scalars).
  defp validate_with_enum(spec, v) do
    case normalize_value(spec, v) do
      {:ok, v2} ->
        if spec[:enum] && v2 not in spec.enum do
          {:error, "must be one of #{inspect(spec.enum)}"}
        else
          {:ok, v2}
        end

      err ->
        err
    end
  end

  @doc """
  Build the JSON Schema map describing this query's input (per MCP spec).
  Used as `input_schema` in the Phantom tool registration.
  """
  @spec to_json_schema(t) :: map
  def to_json_schema(%__MODULE__{params: params}) do
    properties =
      Map.new(params, fn p ->
        {Atom.to_string(p.name), value_schema(p)}
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

  # Recursive JSON Schema for a value spec. Handles scalars + nested
  # arrays/objects so an agent's tool description shows the structure.
  defp value_schema(%{type: :array, items: items_spec} = spec) do
    schema = %{type: "array", items: value_schema(items_spec)}

    schema =
      if spec[:description], do: Map.put(schema, :description, spec.description), else: schema

    schema
  end

  defp value_schema(%{type: :object, properties: props} = spec) do
    nested_props = Map.new(props, fn p -> {Atom.to_string(p.name), value_schema(p)} end)

    nested_required =
      props
      |> Enum.filter(&(&1.required and &1.default == :none))
      |> Enum.map(&Atom.to_string(&1.name))

    schema = %{type: "object", properties: nested_props, required: nested_required}

    schema =
      if spec[:description], do: Map.put(schema, :description, spec.description), else: schema

    schema
  end

  defp value_schema(%{type: t} = spec) do
    schema = %{type: json_type(t)}

    schema =
      if spec[:description], do: Map.put(schema, :description, spec.description), else: schema

    schema = if spec[:enum], do: Map.put(schema, :enum, spec.enum), else: schema
    schema
  end

  defp json_type(:integer), do: "integer"
  defp json_type(:real), do: "number"
  defp json_type(:text), do: "string"
  defp json_type(:blob), do: "string"
  defp json_type(:boolean), do: "boolean"

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
