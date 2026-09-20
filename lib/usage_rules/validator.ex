# SPDX-FileCopyrightText: 2026 usage_rules contributors <https://github.com/ash-project/usage_rules/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule UsageRules.Validator do
  @moduledoc """
  Validates module, function, mix task, and file references found in
  usage-rules-managed markdown files.

  This is the engine behind `mix usage_rules.validate`, and can also be used
  programmatically:

      context = UsageRules.Validator.context_from_mix()
      report = UsageRules.Validator.validate(["AGENTS.md"], context)

      UsageRules.Validator.format_report(report)
      report.summary.errors

  ## Validated reference kinds

    * `Module`, `Module.function`, and `Module.function/arity` patterns, found
      in inline code spans and `elixir`/`iex` fenced code blocks. Verified
      against the project's compiled beams and a static scan of `lib/` sources
      (including umbrella apps and dependencies).
    * `:erlang_module.function/arity` patterns in the same places. Bare
      `:atoms` are never treated as module references, since they are usually
      plain atom literals.
    * `mix task.name` patterns, found in inline code spans and shell or
      untagged fenced code blocks. Verified against mix tasks shipped by the
      project and its dependencies, as well as project aliases.
    * Relative markdown link targets, resolved against the directory of the
      file containing the link.

  Function references are verified against module exports, macros, and
  behaviour callbacks (so `GenServer.handle_call/3` validates correctly).
  References to modules that exist only as uncompiled sources cannot have
  their functions verified; those produce warnings rather than errors.

  Violations are reported with the file, line number, reference, message, and
  a severity of `"error"` or `"warning"`.
  """

  @shell_langs MapSet.new(["sh", "shell", "bash", "zsh", "console", ""])
  @elixir_langs MapSet.new(["elixir", "iex"])
  @excluded_all_dirs MapSet.new(["deps", "_build", "doc", "cover", "node_modules"])

  # Capitalized file names that appear in code spans (e.g. `AGENTS.md`) must
  # not be mistaken for `Module.function` references. Only all-caps document
  # basenames are treated as file names, since real Elixir modules are never
  # fully uppercase (this also keeps functions like `Enum.map/2` and
  # `Phoenix.Component.html/1` validatable).
  @doc_file_names MapSet.new(~w(
    README CHANGELOG LICENSE AGENTS SKILL CONTRIBUTING NOTICE TODO FAQ
    CODEOWNERS AUTHORS VERSION
  ))

  # Extensions checked for the document basenames above.
  @file_extensions MapSet.new(~w(
    md ex exs eex heex leex txt json yaml yml lock toml ini cfg conf env license
  ))

  @candidate_regex ~r/:[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*(?:\/\d+)?|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*[!?]?(?:\/\d+)?/
  @defmodule_regex ~r/^\s*defmodule\s+((?:[A-Z][A-Za-z0-9_]*)(?:\.[A-Z][A-Za-z0-9_]*)*)/m
  @fence_regex ~r/^\s{0,3}(`{3,}|~{3,})\s*(.*)$/
  @inline_span_regex ~r/`([^`\n]+)`/
  @link_regex ~r/\[[^\]\n]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/
  @mix_task_regex ~r/\bmix\s+([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*)/
  @double_quoted_regex ~r/"(?:\\.|[^"\\])*"/
  @comment_regex ~r/#.*/
  @url_regex ~r|https?://\S+|
  @mix_task_module_prefix "Mix.Tasks."

  @doc """
  Builds a validation context from the current mix project.

  Collects module names from compiled beams (the project, its dependencies,
  and everything on the code path) and from a static scan of `lib/` sources,
  plus mix task names and project aliases.
  """
  @spec context_from_mix() :: map()
  def context_from_mix do
    beam_names = beam_module_names()
    source_names = source_module_names()

    %{
      cwd: File.cwd!(),
      beam_module_names: beam_names,
      source_module_names: source_names,
      mix_task_names: mix_task_names(beam_names, source_names)
    }
  end

  @doc """
  Validates the given files against the given context.

  Files may be given as paths (read from disk) or `{path, content}` tuples.
  Returns a report:

      %{
        files: [%{path: path, violations: [violation], references_checked: n}],
        summary: %{files_checked: n, references_checked: n, errors: n, warnings: n}
      }
  """
  @spec validate([Path.t() | {Path.t(), String.t()}], map()) :: map()
  def validate(files, context) when is_list(files) and is_map(context) do
    file_reports =
      files
      |> Enum.map(&normalize_file/1)
      |> Enum.map(&validate_file(&1, context))

    summary = %{
      files_checked: length(file_reports),
      references_checked: Enum.sum(Enum.map(file_reports, & &1.references_checked)),
      errors: count_violations(file_reports, "error"),
      warnings: count_violations(file_reports, "warning")
    }

    %{files: file_reports, summary: summary}
  end

  @doc """
  Returns true when the report should fail validation.

  With `strict?: true`, warnings also cause failure.
  """
  @spec failed?(map(), keyword()) :: boolean()
  def failed?(%{summary: summary}, opts \\ []) do
    summary.errors > 0 or (opts[:strict?] == true and summary.warnings > 0)
  end

  @doc """
  Formats a report for human consumption.
  """
  @spec format_report(map()) :: String.t()
  def format_report(%{files: files, summary: summary}) do
    body =
      files
      |> Enum.reject(&(&1.violations == []))
      |> Enum.map_join("\n", fn %{path: path, violations: violations} ->
        Enum.join(["#{path}:" | Enum.map(violations, &violation_line/1)], "\n")
      end)

    body =
      if body == "" do
        "No reference violations found.\n"
      else
        body <> "\n"
      end

    summary_line =
      "Checked #{summary.files_checked} file(s) and #{summary.references_checked} " <>
        "reference(s): #{summary.errors} error(s), #{summary.warnings} warning(s)"

    body <> summary_line <> "\n"
  end

  @doc """
  Converts a report into a JSON-friendly map (string keys), ready for
  `Jason.encode!/1`.
  """
  @spec json_report(map()) :: map()
  def json_report(%{files: files, summary: summary}) do
    %{
      "status" => if(summary.errors > 0, do: "violations", else: "ok"),
      "summary" => %{
        "files_checked" => summary.files_checked,
        "references_checked" => summary.references_checked,
        "errors" => summary.errors,
        "warnings" => summary.warnings
      },
      "files" =>
        Enum.map(files, fn %{path: path, violations: violations} ->
          %{
            "path" => path,
            "errors" => count_severity(violations, "error"),
            "warnings" => count_severity(violations, "warning"),
            "violations" =>
              Enum.map(violations, fn violation ->
                %{
                  "line" => violation.line,
                  "type" => to_string(violation.type),
                  "severity" => violation.severity,
                  "reference" => violation.reference,
                  "message" => violation.message
                }
              end)
          }
        end)
    }
  end

  # -------------------------------------------------------------------
  # Context building
  # -------------------------------------------------------------------

  defp beam_module_names do
    (compile_path_beams() ++ dep_ebin_beams() ++ code_path_names())
    |> MapSet.new(&normalize_module_name/1)
  end

  defp compile_path_beams do
    case Mix.Project.get() do
      nil ->
        []

      _project ->
        Mix.Project.compile_path()
        |> Path.join("*.beam")
        |> Path.wildcard()
        |> Enum.map(&beam_name/1)
    end
  end

  defp dep_ebin_beams do
    case Mix.Project.get() do
      nil ->
        []

      _project ->
        build_path = Mix.Project.build_path()

        Mix.Project.deps_paths()
        |> Enum.flat_map(fn {app, path} ->
          [
            Path.join([build_path, "lib", to_string(app), "ebin", "*.beam"]),
            Path.join([path, "ebin", "*.beam"])
          ]
        end)
        |> Enum.flat_map(&Path.wildcard/1)
        |> Enum.map(&beam_name/1)
    end
  end

  defp beam_name(beam_path) do
    beam_path |> Path.basename() |> Path.rootname()
  end

  defp code_path_names do
    :code.all_available()
    |> Enum.map(fn {name, _path, _loaded} -> to_string(name) end)
  end

  defp normalize_module_name("Elixir." <> rest), do: rest
  defp normalize_module_name(name), do: name

  defp source_module_names do
    source_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&Regex.run(@defmodule_regex, &1, capture: :all_but_first))
      |> Enum.filter(& &1)
      |> Enum.map(&hd/1)
    end)
    |> MapSet.new()
  end

  defp source_dirs do
    dep_libs =
      case Mix.Project.get() do
        nil ->
          []

        _project ->
          Enum.map(Mix.Project.deps_paths(), fn {_app, path} -> Path.join(path, "lib") end)
      end

    umbrella_libs =
      (Mix.Project.apps_paths() || %{})
      |> Map.values()
      |> Enum.map(&Path.join(&1, "lib"))

    (["lib"] ++ umbrella_libs ++ dep_libs)
    |> Enum.filter(&File.dir?/1)
  end

  defp mix_task_names(beam_names, source_names) do
    task_from_module = fn name ->
      name
      |> String.trim_leading(@mix_task_module_prefix)
      |> String.split(".")
      |> Enum.map_join(".", &Macro.underscore/1)
    end

    from_beams =
      beam_names
      |> Enum.filter(&String.starts_with?(&1, @mix_task_module_prefix))
      |> Enum.map(task_from_module)

    from_sources =
      source_names
      |> Enum.filter(&String.starts_with?(&1, @mix_task_module_prefix))
      |> Enum.map(task_from_module)

    aliases =
      case Mix.Project.get() do
        nil ->
          []

        _project ->
          Mix.Project.config()
          |> Keyword.get(:aliases, [])
          |> Keyword.keys()
          |> Enum.map(&to_string/1)
      end

    MapSet.new(from_beams ++ from_sources ++ aliases)
  end

  # -------------------------------------------------------------------
  # File validation
  # -------------------------------------------------------------------

  defp normalize_file({path, content}), do: %{path: to_string(path), content: content}
  defp normalize_file(path) when is_binary(path), do: %{path: path, content: File.read!(path)}

  defp validate_file(%{path: path, content: content}, context) do
    references = extract_references(path, content)

    violations =
      references
      |> Enum.flat_map(&validate_reference(&1, context))
      |> Enum.uniq_by(&{&1.line, &1.type, &1.reference})
      |> Enum.sort_by(& &1.line)

    %{
      path: path,
      violations: violations,
      references_checked: length(references)
    }
  end

  # -------------------------------------------------------------------
  # Reference extraction
  # -------------------------------------------------------------------

  defp extract_references(path, content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_reduce(%{fence: nil}, fn {line, line_no}, state ->
      {refs, state} = scan_line(line, line_no, state)
      {Enum.map(refs, &Map.put(&1, :file, path)), state}
    end)
    |> elem(0)
    |> List.flatten()
  end

  defp scan_line(line, line_no, %{fence: nil} = state) do
    case Regex.run(@fence_regex, line) do
      [_line, marker, info] ->
        {[], %{fence: {marker, fence_lang(info)}}}

      nil ->
        {inline_references(line, line_no), state}
    end
  end

  defp scan_line(line, line_no, %{fence: {marker, lang}} = state) do
    if fence_close?(line, marker) do
      {[], %{state | fence: nil}}
    else
      {fenced_references(lang, line, line_no), state}
    end
  end

  defp fence_lang(info) do
    info
    |> String.split()
    |> List.first("")
    |> String.downcase()
  end

  defp fence_close?(line, marker) do
    case Regex.run(@fence_regex, line) do
      [_line, close_marker, info] ->
        String.starts_with?(close_marker, String.first(marker)) and String.trim(info) == ""

      nil ->
        false
    end
  end

  defp inline_references(line, line_no) do
    link_refs =
      line
      |> link_targets()
      |> Enum.map(fn target ->
        %{kind: :link, target: target, display: target, line: line_no}
      end)

    span_refs =
      Regex.scan(@inline_span_regex, line, capture: :all_but_first)
      |> Enum.flat_map(fn [span] -> span_references(span, line_no) end)

    Enum.uniq_by(link_refs ++ span_refs, &{&1.kind, &1.display})
  end

  defp span_references(span, line_no) do
    mix_refs =
      @mix_task_regex
      |> Regex.scan(span, capture: :all_but_first)
      |> Enum.map(fn [task] ->
        %{kind: :mix_task, task: task, display: "mix #{task}", line: line_no}
      end)

    module_refs =
      span
      |> strip_noise()
      |> candidate_tokens()
      |> Enum.map(fn token ->
        token
        |> parse_candidate()
        |> case do
          nil -> nil
          ref -> Map.merge(ref, %{display: token, line: line_no})
        end
      end)
      |> Enum.filter(& &1)

    Enum.uniq_by(mix_refs ++ module_refs, &{&1.kind, &1.display})
  end

  defp fenced_references(lang, line, line_no) do
    cond do
      MapSet.member?(@elixir_langs, lang) ->
        line
        |> strip_noise()
        |> candidate_tokens()
        |> Enum.flat_map(fn token ->
          case parse_candidate(token) do
            nil -> []
            ref -> [Map.merge(ref, %{display: token, line: line_no})]
          end
        end)
        |> Enum.uniq_by(&{&1.kind, &1.display})

      MapSet.member?(@shell_langs, lang) ->
        @mix_task_regex
        |> Regex.scan(line, capture: :all_but_first)
        |> Enum.map(fn [task] ->
          %{kind: :mix_task, task: task, display: "mix #{task}", line: line_no}
        end)
        |> Enum.uniq_by(& &1.display)

      true ->
        []
    end
  end

  defp link_targets(line) do
    @link_regex
    |> Regex.scan(line, capture: :all_but_first)
    |> Enum.map(fn [target] -> target end)
    |> Enum.filter(&relative_link?/1)
  end

  defp relative_link?(target) do
    cond do
      String.starts_with?(target, ["#", "/"]) -> false
      Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/, target) -> false
      true -> strip_anchor(target) != ""
    end
  end

  defp strip_anchor(target) do
    target |> String.split("#") |> hd()
  end

  defp strip_noise(text) do
    text
    |> String.replace(@url_regex, " ")
    |> String.replace(@double_quoted_regex, " ")
    |> String.replace(@comment_regex, " ")
  end

  defp candidate_tokens(text) do
    Regex.scan(@candidate_regex, text, capture: :first)
    |> Enum.map(fn [token] -> token end)
  end

  # -------------------------------------------------------------------
  # Token parsing
  # -------------------------------------------------------------------

  defp parse_candidate(":" <> rest), do: parse_erlang_candidate(rest)

  defp parse_candidate(token), do: parse_elixir_candidate(token)

  defp parse_erlang_candidate(rest) do
    {base, arity} = split_arity(rest)

    case String.split(base, ".") do
      [module, function] ->
        %{kind: :erlang_function, module: module, function: function, arity: arity}

      _ ->
        # A bare `:atom` is an atom literal far more often than an erlang
        # module reference, so it is not validated.
        nil
    end
  end

  defp parse_elixir_candidate(token) do
    {base, arity} = split_arity(token)
    base = String.replace_prefix(base, "Elixir.", "")
    segments = String.split(base, ".")

    case segments do
      [single] ->
        if arity == nil and capitalized?(single) and not modified?(single) do
          module_ref(single)
        else
          nil
        end

      _ ->
        {module_segments, [last]} = Enum.split(segments, -1)
        module = Enum.join(module_segments, ".")

        cond do
          capitalized_all?(module_segments) and lowercase_start?(last) and
              not file_name_candidate?(module, last) ->
            %{kind: :elixir_function, module: module, function: last, arity: arity}

          capitalized_all?(segments) and arity == nil and not modified?(last) ->
            module_ref(Enum.join(segments, "."))

          true ->
            nil
        end
    end
  end

  defp module_ref(name) do
    if MapSet.member?(@doc_file_names, name) do
      nil
    else
      %{kind: :elixir_module, module: name, function: nil, arity: nil}
    end
  end

  defp split_arity(token) do
    case String.split(token, "/", parts: 2) do
      [base] ->
        {base, nil}

      [base, arity] ->
        case Integer.parse(arity) do
          {int, ""} -> {base, int}
          _ -> {token, nil}
        end
    end
  end

  defp capitalized?(segment), do: Regex.match?(~r/^[A-Z]/, segment)
  defp lowercase_start?(segment), do: Regex.match?(~r/^[a-z_]/, segment)

  defp capitalized_all?(segments), do: segments != [] and Enum.all?(segments, &capitalized?/1)

  defp modified?(segment), do: String.ends_with?(segment, ["!", "?"])

  defp file_name_candidate?(module, function) do
    MapSet.member?(@doc_file_names, module) and file_extension?(function)
  end

  defp file_extension?(segment) do
    core =
      segment
      |> String.trim_trailing("!")
      |> String.trim_trailing("?")

    MapSet.member?(@file_extensions, String.downcase(core))
  end

  # -------------------------------------------------------------------
  # Reference validation
  # -------------------------------------------------------------------

  defp validate_reference(%{kind: :elixir_module, module: module} = ref, context) do
    if module_exists?(module, context) do
      []
    else
      [violation(ref, "error", :module, "module not found in project or dependencies")]
    end
  end

  defp validate_reference(%{kind: :elixir_function} = ref, context) do
    %{module: module, function: function, arity: arity} = ref

    if module_exists?(module, context) do
      case Code.ensure_loaded(elixir_module(module)) do
        {:module, mod} ->
          check_function(ref, mod, function, arity, true, true)

        {:error, _} ->
          [
            violation(
              ref,
              "warning",
              :function,
              "module is not compiled; cannot verify function"
            )
          ]
      end
    else
      [violation(ref, "error", :module, "module not found in project or dependencies")]
    end
  end

  defp validate_reference(%{kind: :erlang_function, module: module} = ref, context) do
    %{function: function, arity: arity} = ref

    if module_exists?(module, context) do
      case Code.ensure_loaded(String.to_atom(module)) do
        {:module, mod} ->
          check_function(ref, mod, function, arity, false, false)

        {:error, _} ->
          [
            violation(
              ref,
              "warning",
              :function,
              "module is not compiled; cannot verify function"
            )
          ]
      end
    else
      [violation(ref, "error", :module, "module :#{module} not found")]
    end
  end

  defp validate_reference(%{kind: :mix_task, task: task} = ref, context) do
    if MapSet.member?(context.mix_task_names, task) do
      []
    else
      [violation(ref, "error", :mix_task, "mix task not found in project or dependencies")]
    end
  end

  defp validate_reference(%{kind: :link} = ref, context) do
    target = strip_anchor(ref.target)
    dir = ref.file |> Path.expand(context.cwd) |> Path.dirname()
    resolved = Path.expand(target, dir)

    if File.exists?(resolved) do
      []
    else
      [violation(ref, "error", :link, "link target does not exist")]
    end
  end

  defp elixir_module(name), do: String.to_atom("Elixir." <> name)

  defp check_function(ref, mod, function, arity, include_macros?, include_callbacks?) do
    arities =
      module_entries(mod, include_macros?, include_callbacks?)
      |> Enum.filter(fn {name, _arity} -> Atom.to_string(name) == function end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    cond do
      arity != nil and arity in arities ->
        []

      arity == nil and arities != [] ->
        []

      arities != [] ->
        sorted = arities |> Enum.sort() |> Enum.map_join(", ", &Integer.to_string/1)

        [
          violation(
            ref,
            "error",
            :function,
            "function is not defined with arity #{arity} (available arities: #{sorted})"
          )
        ]

      true ->
        [violation(ref, "error", :function, "function is not defined in this module")]
    end
  end

  defp module_entries(mod, include_macros?, include_callbacks?) do
    exports = List.wrap(mod.module_info(:exports))

    macros =
      if include_macros? and function_exported?(mod, :__info__, 1) do
        List.wrap(mod.__info__(:macros))
      else
        []
      end

    callbacks =
      if include_callbacks? do
        # Raises UndefinedFunctionError for modules that are not behaviours.
        try do
          List.wrap(mod.behaviour_info(:callbacks))
        rescue
          _ -> []
        end
      else
        []
      end

    exports ++ macros ++ callbacks
  end

  defp module_exists?(module, context) do
    MapSet.member?(context.beam_module_names, module) or
      MapSet.member?(context.source_module_names, module)
  end

  defp violation(ref, severity, type, message) do
    %{
      file: ref.file,
      line: ref.line,
      type: type,
      severity: severity,
      reference: ref.display,
      message: message
    }
  end

  defp count_violations(file_reports, severity) do
    file_reports
    |> Enum.flat_map(& &1.violations)
    |> count_severity(severity)
  end

  defp count_severity(violations, severity) do
    Enum.count(violations, &(&1.severity == severity))
  end

  defp violation_line(%{severity: severity, line: line, reference: reference, message: message}) do
    "  [#{severity}] line #{line}: #{message} (`#{reference}`)"
  end

  @doc """
  Lists all markdown files in the current project, excluding dependencies,
  build output, docs, and hidden directories. Used by
  `mix usage_rules.validate --all`.
  """
  @spec all_project_files() :: [Path.t()]
  def all_project_files do
    Path.wildcard("**/*.md")
    |> Enum.reject(fn path ->
      path
      |> Path.split()
      |> Enum.any?(&(MapSet.member?(@excluded_all_dirs, &1) or String.starts_with?(&1, ".")))
    end)
  end
end
