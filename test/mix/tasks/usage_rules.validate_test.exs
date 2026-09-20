# SPDX-FileCopyrightText: 2026 usage_rules contributors <https://github.com/ash-project/usage_rules/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.UsageRules.ValidateTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.UsageRules.Validate

  test "prints a notice when no rules-managed files exist" do
    output = capture_io(fn -> Validate.run([]) end)

    assert output =~ "No usage-rules-managed files found"
    assert output =~ "--all"
  end

  test "prints usage for --help" do
    output = capture_io(fn -> Validate.run(["--help"]) end)

    assert output =~ "mix usage_rules.validate"
    assert output =~ "--strict"
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/Invalid options/, fn ->
      capture_io(fn -> Validate.run(["--bogus"]) end)
    end
  end

  test "raises on invalid format" do
    assert_raise Mix.Error, ~r/Invalid --format/, fn ->
      capture_io(fn -> Validate.run(["--format", "yaml"]) end)
    end
  end
end
