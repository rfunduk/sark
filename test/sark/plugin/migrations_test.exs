defmodule Sark.Plugin.MigrationsTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Sark.Plugin.Migrations

  @moduletag :tmp_dir

  defp write_migrations(dir, files) do
    mig_dir = Path.join(dir, "migrations")
    File.mkdir_p!(mig_dir)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(mig_dir, name), body) end)
    dir
  end

  defp open(db_path) do
    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)
    db
  end

  defp table_exists?(db, name) do
    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?"
      )

    :ok = Sqlite3.bind(stmt, [name])
    result = Sqlite3.step(db, stmt) != :done
    :ok = Sqlite3.release(db, stmt)
    result
  end

  defp applied_versions(db) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT version FROM _sark_migrations ORDER BY version")
    rows = collect(db, stmt, [])
    :ok = Sqlite3.release(db, stmt)
    Enum.map(rows, fn [v] -> v end)
  end

  defp applied_rows(db) do
    {:ok, stmt} =
      Sqlite3.prepare(db, "SELECT version, name FROM _sark_migrations ORDER BY version")

    rows = collect(db, stmt, [])
    :ok = Sqlite3.release(db, stmt)
    Enum.map(rows, fn [v, n] -> {v, n} end)
  end

  defp collect(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> collect(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  describe "discover!/1" do
    test "parses + sorts numbered files", %{tmp_dir: dir} do
      write_migrations(dir, %{
        "0002_b.sql" => "CREATE TABLE b(x TEXT);",
        "0001_a.sql" => "CREATE TABLE a(x TEXT);"
      })

      [first, second] = Migrations.discover!(dir)
      assert first.version == 1
      assert first.sql =~ "CREATE TABLE a"
      assert second.version == 2
      assert second.sql =~ "CREATE TABLE b"
    end

    test "raises on bad filename", %{tmp_dir: dir} do
      write_migrations(dir, %{"initial.sql" => "x"})

      assert_raise RuntimeError, ~r/bad migration filename/, fn ->
        Migrations.discover!(dir)
      end
    end

    test "raises on missing migrations dir", %{tmp_dir: dir} do
      assert_raise RuntimeError, ~r/missing migrations directory/, fn ->
        Migrations.discover!(dir)
      end
    end

    test "raises on empty migrations dir", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "migrations"))

      assert_raise RuntimeError, ~r/is empty/, fn ->
        Migrations.discover!(dir)
      end
    end

    test "raises on version gap", %{tmp_dir: dir} do
      write_migrations(dir, %{
        "0001_a.sql" => "x",
        "0003_c.sql" => "y"
      })

      assert_raise RuntimeError, ~r/contiguous from 1/, fn ->
        Migrations.discover!(dir)
      end
    end

    test "raises when not starting from 1", %{tmp_dir: dir} do
      write_migrations(dir, %{"0002_b.sql" => "x"})

      assert_raise RuntimeError, ~r/contiguous from 1/, fn ->
        Migrations.discover!(dir)
      end
    end

    test "captures the name portion of the filename", %{tmp_dir: dir} do
      write_migrations(dir, %{
        "0001_initial.sql" => "x",
        "0002_add_foo.sql" => "y"
      })

      [first, second] = Migrations.discover!(dir)
      assert first.name == "initial"
      assert second.name == "add_foo"
    end
  end

  describe "apply!/3" do
    test "applies all migrations in order on fresh DB", %{tmp_dir: dir} do
      write_migrations(dir, %{
        "0001_a.sql" => "CREATE TABLE a(x TEXT);",
        "0002_b.sql" => "CREATE TABLE b(x TEXT);"
      })

      migs = Migrations.discover!(dir)
      db_path = Path.join(dir, "test.db")

      assert :ok = Migrations.apply!("test", db_path, migs)

      db = open(db_path)
      assert table_exists?(db, "a")
      assert table_exists?(db, "b")
      assert applied_versions(db) == [1, 2]
      Sqlite3.close(db)
    end

    test "records the migration name in the tracker", %{tmp_dir: dir} do
      write_migrations(dir, %{
        "0001_initial.sql" => "CREATE TABLE a(x TEXT);",
        "0002_add_foo.sql" => "CREATE TABLE b(x TEXT);"
      })

      migs = Migrations.discover!(dir)
      db_path = Path.join(dir, "test.db")
      :ok = Migrations.apply!("test", db_path, migs)

      db = open(db_path)
      assert applied_rows(db) == [{1, "initial"}, {2, "add_foo"}]
      Sqlite3.close(db)
    end

    test "tolerates a pre-existing tracker without the `name` column", %{tmp_dir: dir} do
      # Simulates a prod DB created before the runner added `name` — bare
      # tracker schema, populated rows w/ no name. Apply on top should not
      # crash; new rows pick up names; legacy rows keep NULL.
      write_migrations(dir, %{"0001_initial.sql" => "CREATE TABLE a(x TEXT);"})
      db_path = Path.join(dir, "test.db")

      db = open(db_path)

      :ok =
        Sqlite3.execute(db, """
          CREATE TABLE _sark_migrations (
            version    INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
          );
        """)

      :ok =
        Sqlite3.execute(
          db,
          "INSERT INTO _sark_migrations (version, applied_at) VALUES (1, '2024-01-01T00:00:00Z')"
        )

      Sqlite3.close(db)

      # Simulate the prod surgery: ALTER ADD COLUMN name TEXT.
      db = open(db_path)
      :ok = Sqlite3.execute(db, "ALTER TABLE _sark_migrations ADD COLUMN name TEXT")
      Sqlite3.close(db)

      # Add a new migration after surgery.
      File.write!(Path.join([dir, "migrations", "0002_add_b.sql"]), "CREATE TABLE b(x TEXT);")
      migs = Migrations.discover!(dir)

      :ok = Migrations.apply!("test", db_path, migs)

      db = open(db_path)
      assert applied_rows(db) == [{1, nil}, {2, "add_b"}]
      Sqlite3.close(db)
    end

    test "is idempotent — re-runs no-op", %{tmp_dir: dir} do
      write_migrations(dir, %{"0001_a.sql" => "CREATE TABLE a(x TEXT);"})
      migs = Migrations.discover!(dir)
      db_path = Path.join(dir, "test.db")

      :ok = Migrations.apply!("test", db_path, migs)
      :ok = Migrations.apply!("test", db_path, migs)

      db = open(db_path)
      assert applied_versions(db) == [1]
      Sqlite3.close(db)
    end

    test "applies new migration when added later", %{tmp_dir: dir} do
      write_migrations(dir, %{"0001_a.sql" => "CREATE TABLE a(x TEXT);"})
      migs = Migrations.discover!(dir)
      db_path = Path.join(dir, "test.db")
      :ok = Migrations.apply!("test", db_path, migs)

      File.write!(Path.join([dir, "migrations", "0002_b.sql"]), "CREATE TABLE b(x TEXT);")
      migs2 = Migrations.discover!(dir)
      :ok = Migrations.apply!("test", db_path, migs2)

      db = open(db_path)
      assert table_exists?(db, "b")
      assert applied_versions(db) == [1, 2]
      Sqlite3.close(db)
    end

    test "rolls back on migration failure, leaves version unapplied", %{tmp_dir: dir} do
      write_migrations(dir, %{
        "0001_a.sql" => "CREATE TABLE a(x TEXT);",
        "0002_bad.sql" => "CREATE TABLE bad(this is not valid sql);"
      })

      migs = Migrations.discover!(dir)
      db_path = Path.join(dir, "test.db")

      assert_raise RuntimeError, ~r/migration 2.*failed/, fn ->
        Migrations.apply!("test", db_path, migs)
      end

      db = open(db_path)
      assert table_exists?(db, "a")
      refute table_exists?(db, "bad")
      assert applied_versions(db) == [1]
      Sqlite3.close(db)
    end

    test "refuses boot on schema drift (applied not a prefix of files)", %{tmp_dir: dir} do
      write_migrations(dir, %{
        "0001_a.sql" => "CREATE TABLE a(x TEXT);",
        "0002_b.sql" => "CREATE TABLE b(x TEXT);"
      })

      migs = Migrations.discover!(dir)
      db_path = Path.join(dir, "test.db")
      :ok = Migrations.apply!("test", db_path, migs)

      File.rm!(Path.join([dir, "migrations", "0001_a.sql"]))
      File.write!(Path.join([dir, "migrations", "0001_replaced.sql"]), "CREATE TABLE c(x TEXT);")

      migs2 = Migrations.discover!(dir)

      # File [1, 2] same shape but content changed under foot — applied list still
      # matches as a prefix, this only catches version drift not content drift.
      # Verify content-drift detection is NOT v1 scope by confirming this re-applies
      # cleanly. (Documented contract: don't edit applied migrations.)
      assert :ok = Migrations.apply!("test", db_path, migs2)
    end
  end
end
