# SPDX-FileCopyrightText: 2026 usage_rules contributors <https://github.com/ash-project/usage_rules/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule UsageRules.Validator do
  @moduledoc """
  Validates documentation references and file links found in
  usage-rules-managed markdown files.

  This is the engine behind `mix usage_rules.validate`, and can also be used
  programmatically:

      context = UsageRules.Validator.context_from_mix()
      report = UsageRules.Validator.validate(["AGENTS.md"], context)

      UsageRules.Validator.format_report(report)
      report.summary.errors

  ## Reference resolution is delegated to ex_doc

  References are parsed and resolved with `ex_doc` — the same engine that
  autolinks references (and warns about broken ones) when generating HexDocs
  documentation. A reference counts as valid only when ex_doc can resolve it
  against the modules compiled in the project, its dependencies, and
  Erlang/OTP, honoring docs metadata (`@doc`, `@moduledoc`) exactly like a
  docs build does:

    * `Module`, `Module.function/arity`, `m:Module`, `c:Mod.callback/arity`,
      and `t:Mod.type/arity` references, found in inline code spans and in
      `elixir`/`iex` fenced code blocks
    * `:erlang_module.function/arity` references in the same places. Bare
      `:atoms` are never treated as module references, since they are usually
      plain atom literals.
    * `mix task.name` references, found in inline code spans (including
      command lines such as `mix task --flag`) and in shell or untagged
      fenced code blocks. Verified against mix tasks shipped by the project
      and its dependencies.
    * Relative markdown link targets, resolved against the directory of the
      file containing the link.

  Because references are resolved like documentation references, only
  *documented* API validates: targets marked `@doc false` or
  `@moduledoc false` are reported as invalid, and behaviour callbacks must
  use the `c:` prefix, matching ex_doc's own warnings.

  ex_doc must be compiled and available. When it is not, validation fails
  with an actionable error (see `ensure_ex_doc!/1`).

  Violations are reported with the file, line number, reference, message, and
  a severity of `"error"` or `"warning"`.
  """

  @shell_langs MapSet.new(["sh", "shell", "bash", "zsh", "console", ""])
  @elixir_langs MapSet.new(["elixir", "iex"])
  @excluded_all_dirs MapSet.new(["deps", "_build", "doc", "cover", "node_modules"])

  # All-caps document basenames that appear as candidates (e.g. `README`,
  # `SKILL`) are file mentions, not module references.
  @doc_file_names MapSet.new(~w(
    README CHANGELOG LICENSE AGENTS SKILL CONTRIBUTING NOTICE TODO FAQ
    CODEOWNERS AUTHORS VERSION
  ))

  @fence_regex ~r/^\s{0,3}(`{3,}|~{3,})\s*(.*)$/
  @candidate_regex ~r/:[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*(?:\/\d+)?|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*[!?]?(?:\/\d+)?/
  @double_quoted_regex ~r/"(?:\\.|[^"\\])*"/
  @comment_regex ~r/#.*/
  @url_regex ~r|https?://\S+|
  @link_regex ~r/\[[^\]\n]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/
  @mix_task_regex ~r/\bmix\s+([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*)/
  @module_like_regex ~r/^[A-Z][A-Za-z0-9_]*$/

  @doc """
  Builds a validation context from the current mix project.
  """
  @spec context_from_mix() :: map()
  def context_from_mix do
    %{cwd: File.cwd!(), apps: project_apps()}
  end

  @doc """
  Ensures the ex_doc reference machinery is compiled and running, or fails
  with an actionable error.

  `validate/2` resolves references with ex_doc, so it must be compiled and
  available. ex_doc is already a dev dependency of most Hex packages; when it
  is missing, add it to your `mix.exs` and compile it.

  The loader (defaults to `Code.ensure_loaded/1`) is injectable so tests can
  exercise the failure path.
  """
  @spec ensure_ex_doc!((module() -> {:module, module()} | {:error, term()})) :: :ok
  def ensure_ex_doc!(loader \\ &Code.ensure_loaded/1) do
    with {:module, _} <- loader.(ExDoc.Autolink),
         {:module, _} <- loader.(ExDoc.Refs),
         true <- markdown_processor_available?(),
         {:ok, _} <- Application.ensure_all_started(:ex_doc) do
      :ok
    else
      false ->
        Mix.raise(ex_doc_unavailable_message(:earmark_parser_unavailable))

      {:error, reason} ->
        Mix.raise(ex_doc_unavailable_message(reason))
    end
  end

  @doc false
  def ex_doc_unavailable_message(reason) do
    """
    reference validation requires ex_doc, but it is not compiled and available \
    (reason: #{inspect(reason)}).

    ex_doc provides the reference resolution engine used to validate
    documentation references. Most Hex packages already depend on it as a dev
    dependency; make sure it is declared in your mix.exs and compiled:

        defp deps do
          [
            {:ex_doc, "~> 0.37", only: [:dev, :test], runtime: false}
          ]
        end

        $ mix deps.get && mix deps.compile
    """
    |> String.trim_trailing()
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
    ensure_ex_doc!()

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

  defp project_apps do
    case Mix.Project.get() do
      nil ->
        []

      _project ->
        umbrella_apps = Map.keys(Mix.Project.apps_paths() || %{})

        ([Mix.Project.config()[:app]] ++ umbrella_apps)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  # -------------------------------------------------------------------
  # File validation
  # -------------------------------------------------------------------

  defp normalize_file({path, content}), do: %{path: to_string(path), content: content}
  defp normalize_file(path) when is_binary(path), do: %{path: path, content: File.read!(path)}

  defp validate_file(%{path: path, content: content}, context) do
    # ex_doc autolinks inline code spans but deliberately skips fenced code
    # blocks, and earmark does not carry line info for fences. So fences are
    # extracted with a line-accurate scan (and blanked out of the markdown
    # before parsing), while spans are extracted with ex_doc's markdown
    # pipeline. Both feed the same ex_doc resolution step.
    {fences, blanked} = split_fences(content)
    base_config = ex_doc_config(context, path)

    candidates =
      Enum.flat_map(fences, &fence_candidates/1) ++ span_candidates(blanked)

    {ref_violations, refs_checked} =
      Enum.flat_map_reduce(candidates, 0, fn candidate, count ->
        {attempt_candidate(candidate, base_config), count + 1}
      end)

    {link_violations, links_checked} = validate_links(path, blanked, context)

    violations =
      (ref_violations ++ link_violations)
      |> Enum.uniq_by(&{&1.line, &1.type, &1.reference})
      |> Enum.sort_by(&{&1.line, &1.reference})

    %{
      path: path,
      violations: violations,
      references_checked: refs_checked + links_checked
    }
  end

  # -------------------------------------------------------------------
  # ex_doc delegation
  # -------------------------------------------------------------------

  defp ex_doc_config(context, path) do
    # Built with struct/2 (not struct syntax) so this module still compiles
    # in projects that do not have ex_doc compiled.
    struct(ExDoc.Autolink,
      warnings: :send,
      language: ExDoc.Language.Elixir,
      file: path,
      apps: Map.get(context, :apps, []),
      deps: [],
      extras: %{},
      filtered_modules: [],
      skip_undefined_reference_warnings_on: fn _ -> false end,
      skip_code_autolink_to: fn _ -> false end
    )
  end

  # Runs a single candidate through ex_doc's autolinker in strict mode:
  # refs that resolve return a URL, refs that parse but do not resolve make
  # ex_doc send its own warning messages to this process.
  defp attempt_candidate(%{ref: ref, display: display, line: line}, base_config) do
    config = %{base_config | line: line}
    result = ExDoc.Autolink.url(ref, :custom_link, config)
    messages = drain_warnings()

    case {result, messages} do
      {_url, []} ->
        []

      {_, messages} ->
        Enum.map(messages, fn message ->
          %{
            file: base_config.file,
            line: line,
            type: kind_for(ref),
            severity: "error",
            reference: display,
            message: message
          }
        end)
    end
  end

  defp drain_warnings do
    Stream.repeatedly(fn ->
      receive do
        {:warn, message, _meta} -> message
      after
        0 -> :empty
      end
    end)
    |> Enum.take_while(&(&1 != :empty))
  end

  defp markdown_processor_available? do
    ExDoc.Markdown.Earmark.available?()
  rescue
    _ -> false
  end

  # -------------------------------------------------------------------
  # Candidate extraction
  # -------------------------------------------------------------------

  # Returns `{fences, blanked_content}` where fences is a list of
  # `%{lang: lang, lines: [{line_no, line}]}` and blanked_content is the
  # markdown with every fence (markers included) replaced by blank lines so
  # the markdown parser never sees fenced content.
  defp split_fences(content) do
    initial = %{marker: nil, lang: nil, lines: [], fences: []}

    {blanked_lines, final} =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_reduce(initial, fn
        {line, _line_no}, %{marker: nil} = state ->
          case Regex.run(@fence_regex, line) do
            [_line, marker, info] ->
              {"", %{state | marker: marker, lang: fence_lang(info)}}

            nil ->
              {line, state}
          end

        {line, line_no}, %{marker: marker} = state ->
          if fence_close?(line, marker) do
            fence = %{lang: state.lang, lines: state.lines}
            {"", %{state | marker: nil, lang: nil, lines: [], fences: [fence | state.fences]}}
          else
            {"", %{state | lines: [{line_no, line} | state.lines]}}
          end
      end)

    # An unclosed fence consumes everything up to the end of the file.
    open_fence =
      if final.marker do
        [%{lang: final.lang, lines: final.lines}]
      else
        []
      end

    fences =
      final.fences
      |> Enum.concat(open_fence)
      |> Enum.reverse()
      |> Enum.map(fn fence -> Map.update!(fence, :lines, &Enum.reverse/1) end)

    {fences, Enum.join(blanked_lines, "\n")}
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

  defp fence_candidates(%{lang: lang, lines: lines}) do
    cond do
      MapSet.member?(@elixir_langs, lang) ->
        Enum.flat_map(lines, fn {line_no, line} ->
          line
          |> strip_noise()
          |> candidate_tokens()
          |> Enum.flat_map(&candidates_for_token(&1, line_no))
        end)

      MapSet.member?(@shell_langs, lang) ->
        Enum.flat_map(lines, fn {line_no, line} ->
          @mix_task_regex
          |> Regex.scan(line, capture: :all_but_first)
          |> Enum.map(fn [task] -> mix_candidate(task, line_no) end)
        end)

      true ->
        []
    end
  end

  # Inline code spans, extracted with ex_doc's markdown pipeline so span
  # detection matches what a docs build would autolink.
  defp span_candidates(markdown) do
    markdown
    |> ExDoc.Markdown.to_ast(markdown_processor: ExDoc.Markdown.Earmark)
    |> collect_code_spans([])
    |> Enum.flat_map(fn {span, line} -> candidates_for_span(span, line) end)
  end

  defp collect_code_spans({:code, _attrs, [span], meta}, acc) when is_binary(span) do
    [{span, meta[:line] || 1} | acc]
  end

  defp collect_code_spans(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_code_spans/2)
  end

  defp collect_code_spans({_tag, _attrs, children, _meta}, acc) do
    Enum.reduce(List.wrap(children), acc, &collect_code_spans/2)
  end

  defp collect_code_spans(_other, acc), do: acc

  defp candidates_for_span(span, line) do
    span = String.trim(span)

    cond do
      span == "" ->
        []

      # A span naming a mix task may carry arguments or flags; only the task
      # name itself is a verifiable reference.
      String.starts_with?(span, "mix ") ->
        case Regex.run(@mix_task_regex, span, capture: :all_but_first) do
          [task] -> [mix_candidate(task, line)]
          _ -> []
        end

      skipped_candidate?(span) ->
        []

      true ->
        [%{ref: span, display: span, line: line}]
    end
  end

  defp mix_candidate(task, line_no) do
    display = "mix " <> task
    %{ref: display, display: display, line: line_no}
  end

  defp candidates_for_token(token, line_no) do
    if skipped_candidate?(token) do
      []
    else
      [%{ref: token, display: token, line: line_no}]
    end
  end

  # Skips candidates that are common in prose and code but are not
  # documentation references:
  #
  #   * bare `:atoms` (without `/arity`) — usually atom literals
  #   * all-caps document basenames like `README` or `SKILL`
  #   * single segments that are not module names — `foo`, `foo/1`,
  #     `handle_call/3` (ex_doc would resolve those as *local* function
  #     references, which is meaningless outside of module docs)
  defp skipped_candidate?(":" <> rest), do: not String.contains?(rest, "/")

  defp skipped_candidate?(token) do
    cond do
      MapSet.member?(@doc_file_names, token) ->
        true

      match?([_], String.split(token, ".")) ->
        not Regex.match?(@module_like_regex, String.split(token, "/") |> hd())

      true ->
        false
    end
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
  # Link validation
  # -------------------------------------------------------------------

  defp validate_links(path, blanked, context) do
    {targets, links_checked} =
      blanked
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_no} ->
        line
        |> link_targets()
        |> Enum.map(&{line_no, &1})
      end)
      |> Enum.uniq()
      |> then(&{&1, length(&1)})

    violations =
      Enum.flat_map(targets, fn {line_no, target} ->
        dir = path |> Path.expand(context.cwd) |> Path.dirname()
        resolved = Path.expand(strip_anchor(target), dir)

        if File.exists?(resolved) do
          []
        else
          [
            %{
              file: path,
              line: line_no,
              type: :link,
              severity: "error",
              reference: target,
              message: "link target does not exist"
            }
          ]
        end
      end)

    {violations, links_checked}
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

  # -------------------------------------------------------------------
  # Reporting helpers
  # -------------------------------------------------------------------

  defp kind_for("mix " <> _), do: :mix_task
  defp kind_for("c:" <> _), do: :callback
  defp kind_for("t:" <> _), do: :type
  defp kind_for("m:" <> _), do: :module

  defp kind_for(token) do
    if String.contains?(token, "/"), do: :function, else: :module
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
