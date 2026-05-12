defmodule Sark.Plugin.WorkerTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Worker

  describe "parse!/2" do
    test "parses a fully-specified worker" do
      entry = %{
        "description" => "Smoke worker.",
        "model" => "claude-haiku-4-5",
        "tools" => ["list", "get"],
        "max_turns" => 4,
        "system" => "You are.",
        "prompt" => "Do the thing.",
        "schedule" => "0 3 * * *"
      }

      w = Worker.parse!("smoke", entry)

      assert %Worker{
               name: :smoke,
               description: "Smoke worker.",
               model: "claude-haiku-4-5",
               tools: ["list", "get"],
               max_turns: 4,
               system: "You are.",
               prompt: "Do the thing."
             } = w
    end

    test "defaults max_turns to 8" do
      entry = base_entry()
      assert %Worker{max_turns: 8} = Worker.parse!("x", entry)
    end

    test "raises on missing required field" do
      assert_raise ArgumentError, ~r/missing required field `description`/, fn ->
        Worker.parse!("x", base_entry() |> Map.delete("description"))
      end

      assert_raise ArgumentError, ~r/missing required field `model`/, fn ->
        Worker.parse!("x", base_entry() |> Map.delete("model"))
      end

      assert_raise ArgumentError, ~r/missing required field `system`/, fn ->
        Worker.parse!("x", base_entry() |> Map.delete("system"))
      end

      assert_raise ArgumentError, ~r/missing required field `prompt`/, fn ->
        Worker.parse!("x", base_entry() |> Map.delete("prompt"))
      end

      assert_raise ArgumentError, ~r/missing required field `tools`/, fn ->
        Worker.parse!("x", base_entry() |> Map.delete("tools"))
      end

      assert_raise ArgumentError, ~r/missing required field `schedule`/, fn ->
        Worker.parse!("x", base_entry() |> Map.delete("schedule"))
      end
    end

    test "raises on empty tools list" do
      assert_raise ArgumentError, ~r/at least one tool/, fn ->
        Worker.parse!("x", Map.put(base_entry(), "tools", []))
      end
    end

    test "raises on bad tool entry" do
      assert_raise ArgumentError, ~r/non-empty strings/, fn ->
        Worker.parse!("x", Map.put(base_entry(), "tools", [123]))
      end
    end

    test "raises on bad max_turns" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Worker.parse!("x", Map.put(base_entry(), "max_turns", 0))
      end

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Worker.parse!("x", Map.put(base_entry(), "max_turns", "many"))
      end
    end

    test "parses schedule cron expression" do
      assert %Worker{schedule: %Crontab.CronExpression{}} = Worker.parse!("x", base_entry())
    end

    test "raises on invalid cron expression" do
      assert_raise ArgumentError, ~r/invalid cron expression/, fn ->
        Worker.parse!("x", Map.put(base_entry(), "schedule", "not a cron"))
      end
    end

    test "raises on empty schedule string" do
      assert_raise ArgumentError, ~r/missing required field `schedule`/, fn ->
        Worker.parse!("x", Map.put(base_entry(), "schedule", ""))
      end
    end
  end

  defp base_entry do
    %{
      "description" => "x",
      "model" => "m",
      "tools" => ["t"],
      "system" => "s",
      "prompt" => "p",
      "schedule" => "0 3 * * *"
    }
  end
end
