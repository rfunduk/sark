defmodule Sark.Plugin.Query.SQL do
  @moduledoc """
  Rewrite SQL with `:named` bind variables to positional `?` placeholders.

  Returns the rewritten SQL plus the ordered list of names — one entry per
  `?`, so a query that references `:limit` twice will emit two `?`s and
  `[:limit, :limit]`.

  Skips bind-name detection inside:
    * single-quoted string literals (with `''` escape)
    * double-quoted identifier literals (with `""` escape)
    * `--` line comments
    * `/* ... */` block comments
    * `::` PostgreSQL-style casts (recognised conservatively to avoid
      treating the trailing word as a bind name)
  """

  @type result :: {iodata, [atom]}

  @spec compile(String.t()) :: result
  def compile(sql) when is_binary(sql) do
    {acc, names} = scan(sql, [], [])
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(names)}
  end

  # acc :: [iodata]   reversed
  # names :: [atom]   reversed

  defp scan("", acc, names), do: {acc, names}

  defp scan("--" <> rest, acc, names) do
    {after_comment, consumed} = consume_line_comment(rest)
    scan(after_comment, [["--", consumed] | acc], names)
  end

  defp scan("/*" <> rest, acc, names) do
    {after_comment, consumed} = consume_block_comment(rest, [])
    scan(after_comment, [["/*", consumed] | acc], names)
  end

  defp scan("'" <> rest, acc, names) do
    {after_str, consumed} = consume_quoted(rest, ?', [])
    scan(after_str, [["'", consumed] | acc], names)
  end

  defp scan(<<?", rest::binary>>, acc, names) do
    {after_str, consumed} = consume_quoted(rest, ?", [])
    scan(after_str, [[?", consumed] | acc], names)
  end

  defp scan("::" <> rest, acc, names) do
    # Skip the cast token (e.g. `::int`, `::text`) so its name isn't
    # interpreted as a bind variable.
    {after_cast, consumed} = consume_cast_target(rest)
    scan(after_cast, [["::", consumed] | acc], names)
  end

  defp scan(<<?:, c, rest::binary>>, acc, names) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {name_chars, after_name} = consume_name(<<c, rest::binary>>, [])
    name = name_chars |> IO.iodata_to_binary() |> String.to_atom()
    scan(after_name, [?? | acc], [name | names])
  end

  defp scan(<<c, rest::binary>>, acc, names) do
    scan(rest, [c | acc], names)
  end

  defp consume_line_comment(input) do
    case :binary.match(input, "\n") do
      {pos, 1} ->
        <<consumed::binary-size(pos), nl, rest::binary>> = input
        {rest, [consumed, nl]}

      :nomatch ->
        {"", input}
    end
  end

  defp consume_block_comment("", acc), do: {"", Enum.reverse(acc)}
  defp consume_block_comment("*/" <> rest, acc), do: {rest, [Enum.reverse(acc), "*/"]}

  defp consume_block_comment(<<c, rest::binary>>, acc),
    do: consume_block_comment(rest, [c | acc])

  # consume the body of a quoted literal/identifier up to and including
  # the closing quote. SQL escape is doubling the quote character.
  defp consume_quoted("", _q, acc), do: {"", Enum.reverse(acc)}

  defp consume_quoted(<<q, q, rest::binary>>, q, acc) do
    consume_quoted(rest, q, [q, q | acc])
  end

  defp consume_quoted(<<q, rest::binary>>, q, acc) do
    {rest, [Enum.reverse(acc), q]}
  end

  defp consume_quoted(<<c, rest::binary>>, q, acc) do
    consume_quoted(rest, q, [c | acc])
  end

  defp consume_cast_target(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {chars, after_word} = consume_name(<<c, rest::binary>>, [])
    {after_word, chars}
  end

  defp consume_cast_target(rest), do: {rest, []}

  defp consume_name("", acc), do: {Enum.reverse(acc), ""}

  defp consume_name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    consume_name(rest, [c | acc])
  end

  defp consume_name(rest, acc), do: {Enum.reverse(acc), rest}
end
