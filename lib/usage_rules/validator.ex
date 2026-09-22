# SPDX-FileCopyrightText: 2026 usage_rules contributors <https://github.com/ash-project/usage_rules/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule UsageRules.Validator do
  @moduledoc """
  Validates documentation references in usage-rules-managed markdown files
  by driving ex_doc's own autolink pipeline over them.

  This is the engine behind `mix usage_rules.validate`. Each file is parsed
  and autolinked exactly like an extra page in a docs build
  (`ExDoc.Extras.build/2` + `ExDoc.Formatter.autolink/5`), and the warnings
  are ex_doc's own, printed with file/line information — the same warnings
  you would get from a HexDocs build over the same content.

  ## What ex_doc checks

    * function references with arity in inline code spans
      (`Module.function/arity`, `:erlang.function/arity`) — including
      `@doc false` / `@moduledoc false` targets, which are reported as
      "hidden or private"
    * hidden modules mentioned in inline code spans
    * explicit reference links in backtick form: `` [`Mod`](\`Mod\`) `` and
      `` [`mix task`](\`mix task\`) ``
    * relative file links between the validated files (links to files that
      are not part of the validated set do not resolve and are reported)

  ## What ex_doc does not check

  ex_doc deliberately skips fenced code blocks when autolinking, and in
  regular docs builds it stays silent about `mix task` mentions in plain
  code spans and about bare module mentions that do not exist at all. The
  same applies here, with two scoped complements: `validate/1` additionally
  checks `mix task.name` mentions in inline code spans (e.g.
  `` `mix usage_rules.sync --yes` ``) and bare dotted module mentions (e.g.
  `` `NoSuch.Module.Here` ``) using ex_doc's own resolution, reporting
  unknown targets with ex_doc's warning text. Valid, hidden, and
  single-segment module mentions are left to ex_doc's native behavior.

  ex_doc must be compiled and available. When it is not, validation fails
  with an actionable error (see `ensure_ex_doc!/1`).
  """

  @doc """
  Ensures the ex_doc machinery is compiled and running, or fails with an
  actionable error.

  `validate/1` resolves references with ex_doc, so it must be compiled and
  available. ex_doc is already a dev dependency of most Hex packages; when
  it is missing, add it to your `mix.exs` and compile it.

  The loader (defaults to `Code.ensure_loaded/1`) is injectable so tests can
  exercise the failure path.
  """
  @spec ensure_ex_doc!((module() -> {:module, module()} | {:error, term()})) :: :ok
  def ensure_ex_doc!(loader \\ &Code.ensure_loaded/1) do
    with {:module, _} <- loader.(ExDoc.Formatter),
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
  Validates the given markdown files (paths on disk) with ex_doc's own
  autolink pipeline.

  ex_doc's warnings are printed to stderr as they are found, in ex_doc's own
  format with file/line information. Returns:

      %{files: [path], warned?: boolean()}

  `warned?` is true when ex_doc emitted at least one warning, which callers
  should treat as validation failure.
  """
  @spec validate([Path.t()]) :: %{files: [Path.t()], warned?: boolean()}

  # Everything that touches ex_doc modules is compiled only when ex_doc is
  # available, so projects that use usage_rules as a dev dependency without
  # ex_doc compiled still compile this module cleanly. Calling validate/1
  # there fails fast with the actionable error from ensure_ex_doc!/1.
  if Code.ensure_loaded?(ExDoc) do
    # The flag `ExDoc.warn/2` sets whenever it emits a warning. ex_doc's own
    # CLI uses it (via `ExDoc.generate_docs/4`'s `warned?` result) to decide
    # the exit status of docs builds; we read the same flag after running
    # ex_doc's autolink phase.
    @warned_flag {ExDoc, :warned?}

    @mix_task_regex ~r/^mix\s+([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*)/

    def validate(files) when is_list(files) do
      ensure_ex_doc!()

      :persistent_term.erase(@warned_flag)

      # ExDoc structs are built with struct/2 (not struct expansion syntax) so
      # this module still compiles in projects that do not have ex_doc
      # compiled; validate/1 requires it only at runtime. The flag key is read
      # and erased the same way ex_doc's own CLI decides the docs build exit
      # status.
      config = struct(ExDoc.Config, [])
      extras = ExDoc.Extras.build(files, config)

      Enum.each(extras, &validate_span_complements/1)

      formatter_config =
        struct(ExDoc.Formatter.Config, apps: project_apps(), deps: [])

      ExDoc.Formatter.autolink(formatter_config, [], [], extras, extension: ".html")

      %{files: files, warned?: :persistent_term.get(@warned_flag, false)}
    end

    defp markdown_processor_available?, do: ExDoc.Markdown.Earmark.available?()

    # -------------------------------------------------------------------
    # complements: mix tasks and bare modules in code spans
    # -------------------------------------------------------------------

    # ex_doc's autolink phase is deliberately permissive in regular docs
    # builds, so two reference kinds that usage-rules files rely on get no
    # native warning: `mix task` mentions in plain code spans, and bare
    # undefined module mentions (`NoSuch.Module.Here`). Both are scoped
    # complements here: candidates are pushed through ex_doc's own resolution
    # (`ExDoc.Autolink.url/3` in strict mode), warnings are collected via
    # ex_doc's `warnings: :send` mode and re-emitted with `ExDoc.warn/2` so
    # they print (and set the warned flag) exactly like native warnings.

    # A bare module span is a dotted alias chain with only uppercase-first
    # segments (`Foo.Bar`, `NoSuch.Module.Here`). Single segments (`Enum`),
    # atoms (`:ok`), function refs (`Foo.bar/1`), and file names (`SKILL.md`)
    # are not candidates.
    @module_span_regex ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+$/

    defp validate_span_complements(%{__struct__: ExDoc.ExtraNode, doc: doc, source_path: path}) do
      # Struct built with struct/2 for compile-time safety without ex_doc.
      config =
        struct(ExDoc.Autolink,
          warnings: :send,
          language: ExDoc.Language.Elixir,
          file: path,
          apps: project_apps(),
          deps: []
        )

      walk_spans(doc, config)
    end

    defp validate_span_complements(_other), do: :ok

    # Fenced code blocks are skipped, matching ex_doc's own autolinking.
    defp walk_spans({:pre, _, _, _}, _config), do: :ok

    # Links are validated natively by the autolink phase; don't double-report.
    defp walk_spans({:a, _, _, _}, _config), do: :ok

    defp walk_spans({:code, _, [code], meta}, config) do
      code = String.trim(code)

      cond do
        task = mix_task_name(code) ->
          check_span("mix " <> task, meta[:line], config)

        Regex.match?(@module_span_regex, code) ->
          check_bare_module_span(code, meta[:line], config)

        true ->
          :ok
      end
    end

    defp walk_spans(list, config) when is_list(list) do
      Enum.each(list, &walk_spans(&1, config))
    end

    defp walk_spans({_tag, _attrs, children, _meta}, config) do
      walk_spans(List.wrap(children), config)
    end

    defp walk_spans(_other, _config), do: :ok

    defp mix_task_name(code) do
      case Regex.run(@mix_task_regex, code, capture: :all_but_first) do
        [task] -> task
        _ -> nil
      end
    end

    defp check_bare_module_span(code, line, config) do
      # Only warn where the native pass is silent: modules that do not exist
      # at all. Valid, hidden, and limited modules are already handled (or
      # accepted) by ex_doc's autolink phase.
      case ExDoc.Language.Elixir.parse_module(code, :custom_link) do
        {:module, module} ->
          if ExDoc.Refs.get_visibility({:module, module}) == :undefined do
            check_span(code, line, config)
          end

        :error ->
          :ok
      end
    end

    defp check_span(ref, line, config) do
      config = %{config | line: line}
      ExDoc.Autolink.url(ref, :custom_link, config)
      Enum.each(drain_warnings(), &ExDoc.warn(&1, file: config.file, line: config.line))
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

    # -------------------------------------------------------------------
    # Project context
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
  else
    def validate(_files) do
      ensure_ex_doc!()
    end

    defp markdown_processor_available?, do: false
  end
end
