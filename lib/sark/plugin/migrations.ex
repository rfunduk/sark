defmodule Sark.Plugin.Migrations do
  @moduledoc """
  Forward-only SQL migrations per plugin.

  Each plugin ships a `migrations/` directory of numbered SQL files
  (`0001_initial.sql`, `0002_add_x.sql`, …). On boot, sark applies
  any not-yet-applied migrations in order, tracking the applied set
  in a per-plugin `_sark_migrations` table.

  Rules:
    * file versions must be contiguous from 1 (no gaps in the source set)
    * applied set must be a prefix of the file set (no missing-but-applied)
    * each migration runs in its own transaction; failure leaves it unapplied
    * forward-only — no down migrations
    * never edit an applied migration; sark doesn't enforce, contract only

  Apply delegates to `Sark.Migrations` — the shared runner also used
  by the sark-internal migration track.
  """

  @doc """
  Discover migrations under `<plugin_dir>/migrations/`. Returns
  `[%{version, name, path, sql}]` sorted ascending by version. Raises
  on bad filenames or version gaps.
  """
  @spec discover!(Path.t()) :: [Sark.Migrations.migration()]
  def discover!(plugin_dir) do
    mig_dir = Path.join(plugin_dir, "migrations")
    Sark.Migrations.discover!(mig_dir, "plugin #{plugin_dir}")
  end

  @doc """
  Apply any unapplied migrations against the DB at `db_path`.
  Delegates to `Sark.Migrations` with the plugin-track tracker name.
  """
  @spec apply!(String.t(), Path.t(), [Sark.Migrations.migration()]) :: :ok
  def apply!(plugin_name, db_path, migrations) do
    Sark.Migrations.apply!(
      source_label: "plugin #{plugin_name}",
      db_path: db_path,
      migrations: migrations,
      tracker_table: "_sark_migrations"
    )
  end
end
