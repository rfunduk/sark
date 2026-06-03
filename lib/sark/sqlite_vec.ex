defmodule Sark.SqliteVec do
  @moduledoc """
  Provisioning + helpers for the `sqlite-vec` (`vec0`) loadable extension.

  Replaces the abandoned `:sqlite_vec` hex wrapper (frozen at 0.1.0, whose
  bundled `linux-aarch64` loadable for sqlite-vec 0.1.5/0.1.6 is a
  *mislabeled 32-bit ARM binary* — see the `vec0-elfclass32-arm64` jot).
  We pin sqlite-vec #{"0.1.7"} (first correct aarch64 build) and fetch the
  loadable ourselves, sha-verified and ELF-class-asserted at install time.

  Two responsibilities:

    * `install!/1` — download the host-appropriate loadable and place it in
      `priv/sqlite_vec/`. Run via `mix sark.vec0` (build + local dev).
    * `path/0` — extensionless path to the loadable. SQLite's
      `load_extension/1` appends the platform suffix (`.so` / `.dylib`),
      which is how a single path works across OSes.
  """

  @version "0.1.7"

  # {os, arch} => {loadable_filename, sha256(tarball)}
  # sha256 are of the upstream `sqlite-vec-<v>-loadable-<os>-<arch>.tar.gz`
  # release assets. Bump alongside @version.
  @artifacts %{
    {:linux, :x86_64} =>
      {"vec0.so", "87f765c2ece1e91248274faf725e8798af492d989bebb4aa12d874600683ef61"},
    {:linux, :aarch64} =>
      {"vec0.so", "e7cb69d7ca594b977fdd00d780cef038cbc4ba1899990132bbf02cb3175bda2a"},
    {:macos, :x86_64} =>
      {"vec0.dylib", "0df45f64307367060d43e6809aadffbe2270b4aa156f2eb3a09d8aacb9a3a100"},
    {:macos, :aarch64} =>
      {"vec0.dylib", "36455fa1424f34d97d5171e35de8546a0c83f421e603b64d0f0cc6f6af5e5abe"}
  }

  @doc """
  Extensionless path to the loadable. Pass to SQLite `load_extension/1`,
  which appends `.so` / `.dylib`.
  """
  @spec path() :: String.t()
  def path, do: Application.app_dir(:sark, ["priv", "sqlite_vec", "vec0"])

  @doc """
  Packs a list of floats into the little-endian float32 binary that a `vec0`
  `float[N]` column expects.
  """
  @spec float32_to_binary([number()]) :: binary()
  def float32_to_binary(list) when is_list(list) do
    for v <- list, into: <<>>, do: <<v::float-32-little>>
  end

  @doc """
  Download + install the loadable for the current host into `priv/sqlite_vec/`.

  Idempotent: skips the download when a valid loadable is already present
  unless `force: true`.
  """
  @spec install!(keyword()) :: :ok
  def install!(opts \\ []) do
    {os, arch} = target()

    {filename, sha} =
      Map.get(@artifacts, {os, arch}) ||
        raise "sqlite-vec: no pinned loadable for #{os}-#{arch} (v#{@version})"

    dest_dir = Path.dirname(path())
    dest = Path.join(dest_dir, filename)

    if not opts[:force] and File.exists?(dest) and valid_magic?(os, File.read!(dest)) do
      log("sqlite-vec: #{filename} already present, skipping")
      :ok
    else
      File.mkdir_p!(dest_dir)
      bin = fetch_and_extract!(os, arch, filename, sha)
      verify_magic!(os, bin)
      File.write!(dest, bin)
      log("sqlite-vec: installed #{filename} (#{os}-#{arch}, v#{@version}) -> #{dest}")
      :ok
    end
  end

  @doc "sqlite-vec loadable version this build pins."
  def version, do: @version

  # --- internals ---

  defp fetch_and_extract!(os, arch, filename, expected_sha) do
    url =
      "https://github.com/asg017/sqlite-vec/releases/download/v#{@version}/" <>
        "sqlite-vec-#{@version}-loadable-#{os}-#{arch}.tar.gz"

    log("sqlite-vec: downloading #{url}")
    %{status: 200, body: tarball} = Req.get!(url, redirect: true, decode_body: false)

    actual_sha = :crypto.hash(:sha256, tarball) |> Base.encode16(case: :lower)

    unless actual_sha == expected_sha do
      raise "sqlite-vec: checksum mismatch for #{url}\n  expected #{expected_sha}\n  got      #{actual_sha}"
    end

    {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

    case List.keyfind(files, String.to_charlist(filename), 0) do
      {_name, content} ->
        content

      nil ->
        raise "sqlite-vec: #{filename} not found in #{url} (got: #{inspect(Enum.map(files, &elem(&1, 0)))})"
    end
  end

  # Guard against the exact upstream bug: a 32-bit loadable on a 64-bit host.
  defp verify_magic!(os, bin) do
    unless valid_magic?(os, bin) do
      raise "sqlite-vec: loadable failed #{os} 64-bit magic check " <>
              "(first bytes: #{bin |> binary_part(0, min(8, byte_size(bin))) |> Base.encode16(case: :lower)})"
    end
  end

  # ELFCLASS64: 7f 45 4c 46 02  ("\x7fELF", EI_CLASS=2)
  defp valid_magic?(:linux, <<0x7F, ?E, ?L, ?F, 0x02, _::binary>>), do: true
  # Mach-O 64-bit (MH_MAGIC_64, little-endian): cf fa ed fe
  defp valid_magic?(:macos, <<0xCF, 0xFA, 0xED, 0xFE, _::binary>>), do: true
  defp valid_magic?(_, _), do: false

  defp target do
    arch_str = :erlang.system_info(:system_architecture) |> List.to_string()

    arch =
      cond do
        arch_str =~ ~r/(aarch64|arm64)/ -> :aarch64
        arch_str =~ ~r/(x86_64|amd64)/ -> :x86_64
        true -> raise "sqlite-vec: unsupported architecture #{inspect(arch_str)}"
      end

    if :erlang.system_info(:wordsize) * 8 != 64 do
      raise "sqlite-vec: 32-bit BEAM not supported (arch=#{arch_str})"
    end

    os =
      case :os.type() do
        {:unix, :darwin} -> :macos
        {:unix, _} -> :linux
        other -> raise "sqlite-vec: unsupported OS #{inspect(other)}"
      end

    {os, arch}
  end

  defp log(msg) do
    if Code.ensure_loaded?(Mix), do: Mix.shell().info(msg), else: IO.puts(msg)
  end
end
