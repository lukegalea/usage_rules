# SPDX-FileCopyrightText: 2026 usage_rules contributors <https://github.com/ash-project/usage_rules/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.UsageRules.Validate do
  use Mix.Task

  @shortdoc "Validates references in usage-rules-managed files"

  @moduledoc """
  Validates module, function, mix task, and file references found in the
  files generated and managed by `mix usage_rules.sync`.

  Checks that `Module`, `Module.function/arity`, and `:erlang.module/arity`
  references resolve against your project and its dependencies, that
  `mix task.name` references are real tasks (or aliases), and that relative
  markdown links point at files that exist.

  ## Scope

  By default, only rules-managed files are validated:

    * the composed file from the `:file` option of your `:usage_rules` config
      (e.g. `AGENTS.md`)
    * `*.md` files under skills managed by usage-rules (skills whose
      `SKILL.md` contains `managed-by: usage-rules`)

  Use `--all` to validate every markdown file in the project instead
  (excluding `deps/`, `_build/`, `doc/`, and hidden directories).

  ## Examples

      $ mix usage_rules.validate
      $ mix usage_rules.validate --strict
      $ mix usage_rules.validate --all
      $ mix usage_rules.validate --format json

  ## Options

    * `--format` - `human` (default) or `json`
    * `--strict` - treat warnings as failures. Warnings are emitted when a
      reference cannot be fully verified, e.g. a function reference to a
      module that exists only as an uncompiled source file.
    * `--all` - validate all markdown files in the project, not just
      rules-managed files
    * `--help` - show this usage information

  ## Exit status

  Exits with a nonzero status when unresolvable references are found, making
  the task suitable for CI. With `--strict`, warnings also cause a nonzero
  exit.
  """

  @switches [format: :string, strict: :boolean, all: :boolean, help: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _remaining, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}\n\n#{usage()}")
    end

    if opts[:help] do
      Mix.shell().info(usage())
    else
      validate(opts)
    end
  end

  defp validate(opts) do
    unless Mix.Project.get() do
      Mix.raise("mix usage_rules.validate must be run inside a Mix project")
    end

    format = normalize_format(opts[:format])

    files =
      if opts[:all] do
        UsageRules.Validator.all_project_files()
      else
        managed_files()
      end

    if files == [] do
      Mix.shell().info(no_files_message(opts[:all]))
    else
      context = UsageRules.Validator.context_from_mix()
      report = UsageRules.Validator.validate(files, context)

      output =
        case format do
          "json" -> UsageRules.Validator.json_report(report) |> Jason.encode!()
          _human -> UsageRules.Validator.format_report(report)
        end

      Mix.shell().info(output)

      if UsageRules.Validator.failed?(report, strict?: !!opts[:strict]) do
        exit({:shutdown, 1})
      end
    end
  end

  defp managed_files do
    config = Mix.Project.config()[:usage_rules] || []
    composed_file(config) ++ managed_skill_files(Keyword.get(config, :skills) || [])
  end

  defp composed_file(config) do
    case Keyword.get(config, :file) do
      nil -> []
      file -> if File.regular?(file), do: [file], else: []
    end
  end

  defp managed_skill_files(skills_config) do
    location = Keyword.get(skills_config, :location, ".claude/skills")

    Path.wildcard(Path.join(location, "*/SKILL.md"))
    |> Enum.filter(&(File.read!(&1) =~ "managed-by: usage-rules"))
    |> Enum.flat_map(fn skill_md ->
      skill_md
      |> Path.dirname()
      |> then(&Path.wildcard(Path.join(&1, "**/*.md")))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_format(nil), do: "human"

  defp normalize_format(format) when format in ~w(human json), do: format

  defp normalize_format(other) do
    Mix.raise(~s"""
    Invalid --format #{inspect(other)}. Expected "human" or "json".

    #{usage()}
    """)
  end

  defp no_files_message(all?) do
    if all? do
      "No markdown files found to validate."
    else
      """
      No usage-rules-managed files found to validate.

      Add a :usage_rules config to your mix.exs and run `mix usage_rules.sync`,
      or pass --all to validate every markdown file in the project.
      """
      |> String.trim_trailing()
    end
  end

  defp usage do
    """
    mix usage_rules.validate [--format human|json] [--strict] [--all]

    Validates module, function, mix task, and file references in
    usage-rules-managed files (or all markdown files with --all).
    Exits nonzero when unresolvable references are found.
    """
  end
end
