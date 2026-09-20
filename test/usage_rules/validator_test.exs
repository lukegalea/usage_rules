# SPDX-FileCopyrightText: 2026 usage_rules contributors <https://github.com/ash-project/usage_rules/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule UsageRules.ValidatorTest do
  use ExUnit.Case, async: true

  @fixture_path Path.join(["test", "fixtures", "validate", "rules.md"])

  setup do
    context = UsageRules.Validator.context_from_mix()

    broken_refs = [
      "NoSuch.Module.Xyz",
      "NoSuchModuleAnywhere",
      "Enum.definitely_not_real/2",
      "Enum.map/9",
      ":timer.definitely_not_real/1",
      ":no_such_erlang_module.foo/1",
      "mix definitely_not_a_real_task",
      "missing.md",
      "Flagged.In.Fence"
    ]

    %{context: context, broken_refs: broken_refs}
  end

  describe "validate/2 with the fixture rules file" do
    test "reports every deliberately broken reference", %{
      context: context,
      broken_refs: broken_refs
    } do
      report = UsageRules.Validator.validate([@fixture_path], context)
      violations = hd(report.files).violations
      reported = Enum.map(violations, & &1.reference)

      for broken <- broken_refs do
        assert broken in reported, "expected #{broken} to be reported, got: #{inspect(reported)}"
      end

      assert length(violations) == length(broken_refs)
      assert report.summary.errors == length(broken_refs)
      assert report.summary.warnings == 0
    end

    test "does not report valid references or known false positives", %{
      context: context,
      broken_refs: broken_refs
    } do
      report = UsageRules.Validator.validate([@fixture_path], context)
      reported = hd(report.files).violations |> Enum.map(& &1.reference)

      for valid <- [
            "Enum",
            "Enum.map/2",
            "Mix.Tasks.UsageRules.List",
            "UsageRules.Validator",
            "String.upcase/1",
            "GenServer.handle_call/3",
            ":timer.tc/3",
            "mix usage_rules.docs",
            "mix usage_rules.list",
            "mix usage_rules.search_docs",
            "exists.md"
          ] do
        refute valid in reported, "did not expect #{valid} to be reported"
      end

      # File names in code spans and strings/comments must not be treated
      # as module references.
      for false_positive <- ["AGENTS.md", "SKILL.md", "mix.exs", "Skipped.Module", "hello"] do
        refute false_positive in reported
      end

      assert report.summary.references_checked > length(broken_refs)
    end

    test "records file and line for each violation", %{context: context} do
      report = UsageRules.Validator.validate([@fixture_path], context)
      file_report = hd(report.files)

      assert file_report.path == @fixture_path

      Enum.each(file_report.violations, fn violation ->
        assert %{
                 file: @fixture_path,
                 line: line,
                 type: type,
                 severity: severity,
                 reference: reference,
                 message: message
               } = violation

        assert is_integer(line) and line > 0
        assert type in [:module, :function, :mix_task, :link]
        assert severity in ["error", "warning"]
        assert is_binary(reference) and reference != ""
        assert is_binary(message) and message != ""
      end)
    end

    test "classifies violation types", %{context: context} do
      violations = hd(UsageRules.Validator.validate([@fixture_path], context).files).violations

      by_ref = Map.new(violations, fn v -> {v.reference, v.type} end)

      assert by_ref["NoSuch.Module.Xyz"] == :module
      assert by_ref["Enum.definitely_not_real/2"] == :function
      assert by_ref["Enum.map/9"] == :function
      assert by_ref["mix definitely_not_a_real_task"] == :mix_task
      assert by_ref["missing.md"] == :link
    end

    test "mentions available arities on arity mismatches", %{context: context} do
      violations = hd(UsageRules.Validator.validate([@fixture_path], context).files).violations

      Enum.each(violations, fn violation ->
        if violation.reference == "Enum.map/9" do
          assert violation.message =~ "available arities"
        end
      end)
    end

    test "deduplicates identical references on the same line", %{context: context} do
      content = "Broken here: `NoSuch.Module.Xyz` and again `NoSuch.Module.Xyz`\n"

      report = UsageRules.Validator.validate([{"inline.md", content}], context)

      assert hd(report.files).violations |> Enum.count(&(&1.reference == "NoSuch.Module.Xyz")) ==
               1
    end
  end

  describe "validate/2 with explicit content" do
    test "validates {path, content} pairs without reading from disk", %{context: context} do
      content = "See `NoSuch.Module.Xyz` and `Enum.map/2`.\n"

      report = UsageRules.Validator.validate([{"memory.md", content}], context)
      violations = hd(report.files).violations

      assert Enum.map(violations, & &1.reference) == ["NoSuch.Module.Xyz"]
      assert hd(report.files).references_checked == 2
    end
  end

  describe "module resolution" do
    test "flags modules missing from both beams and sources", %{context: context} do
      report = UsageRules.Validator.validate([{"m.md", "`Definitely.Not.A.Module`"}], context)
      violations = hd(report.files).violations

      assert [%{type: :module, severity: "error"}] = violations
    end

    test "accepts modules that only exist as uncompiled sources" do
      context = %{
        UsageRules.Validator.context_from_mix()
        | source_module_names: MapSet.put(MapSet.new(), "Fake.Source.Only")
      }

      report = UsageRules.Validator.validate([{"m.md", "`Fake.Source.Only`"}], context)

      assert hd(report.files).violations == []
    end

    test "downgrades function checks on uncompiled modules to warnings" do
      context = %{
        UsageRules.Validator.context_from_mix()
        | source_module_names: MapSet.put(MapSet.new(), "Fake.Source.Only")
      }

      report =
        UsageRules.Validator.validate([{"m.md", "`Fake.Source.Only.do_thing/1`"}], context)

      assert [%{severity: "warning", type: :function}] = hd(report.files).violations
    end

    test "reports erlang module refs only through :module.function form" do
      context = UsageRules.Validator.context_from_mix()

      content = "Atoms are fine: `:ok`, `:error`, but `:ets.insert/2` must exist.\n"
      report = UsageRules.Validator.validate([{"m.md", content}], context)

      assert hd(report.files).violations == []
    end
  end

  describe "fenced code block handling" do
    test "scans elixir blocks, skips strings and comments" do
      context = UsageRules.Validator.context_from_mix()

      content = """
      ```elixir
      alias Safe.String.Module
      skip = "Inside.String.Ignored"
      # Inside.Comment.Ignored
      Flagged.In.Fence
      ```
      """

      refs =
        UsageRules.Validator.validate([{"m.md", content}], context)
        |> then(&hd(&1.files).violations)
        |> Enum.map(& &1.reference)

      assert refs == ["Safe.String.Module", "Flagged.In.Fence"]
    end

    test "scans shell and untagged blocks only for mix tasks" do
      context = UsageRules.Validator.context_from_mix()

      content = """
      ```sh
      mix usage_rules.docs NoSuchModule
      ```

      ```
      mix usage_rules.list
      ```
      """

      report = UsageRules.Validator.validate([{"m.md", content}], context)

      assert hd(report.files).violations == []
    end

    test "skips unrecognized languages entirely" do
      context = UsageRules.Validator.context_from_mix()

      content = """
      ```json
      {"module": "Json.Not.Checked"}
      ```
      """

      report = UsageRules.Validator.validate([{"m.md", content}], context)

      assert hd(report.files).violations == []
    end

    test "stops scanning at the closing fence" do
      context = UsageRules.Validator.context_from_mix()

      content = """
      ```elixir
      Fence.Bad.Module
      ```
      Plain prose `Enum.map/2`
      """

      refs =
        UsageRules.Validator.validate([{"m.md", content}], context)
        |> then(&hd(&1.files).violations)
        |> Enum.map(& &1.reference)

      assert refs == ["Fence.Bad.Module"]
    end
  end

  describe "link handling" do
    @tag :tmp_dir
    test "resolves relative links against the containing file", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "target.md")
      File.write!(target, "target\n")

      source_path = Path.join(tmp_dir, "source.md")
      File.write!(source_path, "[good](target.md)\n[bad](missing.md)\n")

      context = UsageRules.Validator.context_from_mix()
      violations = hd(UsageRules.Validator.validate([source_path], context).files).violations

      assert Enum.map(violations, & &1.reference) == ["missing.md"]
      assert hd(violations).type == :link
    end

    test "ignores anchors, absolute paths, and urls", %{context: context} do
      content = """
      [a](#section)
      [b](/absolute/path.md)
      [c](https://hexdocs.pm/elixir/Enum.html)
      [d](mailto:someone@example.com)
      """

      report = UsageRules.Validator.validate([{"m.md", content}], context)

      assert hd(report.files).violations == []
    end
  end

  describe "failed?/2" do
    test "returns true when there are errors", %{context: context} do
      report = UsageRules.Validator.validate([{"m.md", "`NoSuch.Module.Xyz`"}], context)

      assert UsageRules.Validator.failed?(report)
    end

    test "returns false for warnings unless strict", %{context: context} do
      report = UsageRules.Validator.validate([{"m.md", "just prose"}], context)

      refute UsageRules.Validator.failed?(report)
      refute UsageRules.Validator.failed?(report, strict?: true)
    end

    test "strict mode fails on warnings" do
      context = %{
        UsageRules.Validator.context_from_mix()
        | source_module_names: MapSet.put(MapSet.new(), "Fake.Source.Only")
      }

      report =
        UsageRules.Validator.validate([{"m.md", "`Fake.Source.Only.do_thing/1`"}], context)

      refute UsageRules.Validator.failed?(report)
      assert UsageRules.Validator.failed?(report, strict?: true)
    end
  end

  describe "format_report/1" do
    test "lists violations with file, line, severity, and counts", %{context: context} do
      report = UsageRules.Validator.validate([@fixture_path], context)
      output = UsageRules.Validator.format_report(report)

      assert output =~ @fixture_path
      assert output =~ "[error]"
      assert output =~ "line "
      assert output =~ "error(s)"
      assert output =~ "warning(s)"
    end

    test "reports a clean result for valid content", %{context: context} do
      report = UsageRules.Validator.validate([{"m.md", "`Enum.map/2` is real.\n"}], context)

      assert UsageRules.Validator.format_report(report) =~ "No reference violations found."
    end
  end

  describe "json_report/1" do
    test "produces a JSON-friendly structure", %{context: context} do
      report = UsageRules.Validator.validate([@fixture_path], context)
      json = UsageRules.Validator.json_report(report)

      assert json["status"] == "violations"
      assert json["summary"]["errors"] == report.summary.errors
      assert json["summary"]["files_checked"] == 1

      [file_report] = json["files"]
      assert file_report["path"] == @fixture_path
      assert length(file_report["violations"]) == report.summary.errors

      Enum.each(file_report["violations"], fn violation ->
        assert MapSet.subset?(
                 MapSet.new(Map.keys(violation)),
                 MapSet.new(~w(line type severity reference message))
               )

        assert violation["type"] in ["module", "function", "mix_task", "link"]
        assert violation["severity"] in ["error", "warning"]
      end)
    end

    test "marks clean runs as ok", %{context: context} do
      report = UsageRules.Validator.validate([{"m.md", "`Enum.map/2`.\n"}], context)
      json = UsageRules.Validator.json_report(report)

      assert json["status"] == "ok"
      assert json["files"] |> hd() |> Map.fetch!("violations") == []
    end
  end
end
