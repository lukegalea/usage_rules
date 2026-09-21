# Fixture rules

Good module refs: `Enum`, `Mix.Tasks.UsageRules.List`, `UsageRules.Validator`.

Bad module refs: `NoSuch.Module.Xyz`, `NoSuchModuleAnywhere`.

Good function refs: `String.upcase/1`, `:timer.tc/3`.

Callbacks need the `c:` prefix to be references: `c:GenServer.handle_call/3` is good, `GenServer.handle_call/3` is bad.

Bad function refs: `Enum.definitely_not_real/2`, `Enum.map/9`, `:timer.definitely_not_real/1`, `:no_such_erlang_module.foo/1`.

Good mix task: `mix usage_rules.docs`. Bad mix task: `mix definitely_not_a_real_task`.

Tasks with flags only validate the task name: `mix usage_rules.list --help`.

Undocumented modules are flagged: `Mix.Tasks.UsageRules.Sync.Docs`.

Capitalized file names and bare atoms in spans are not module refs: `AGENTS.md`, `SKILL.md`, `mix.exs`, `:ok`.

Links: [good](exists.md), [broken](missing.md), [anchor](#section), [remote](https://hexdocs.pm/elixir), [absolute](/etc/hosts).

```elixir
String.upcase("hello") # comment with `Skipped.Module`
Enum.map/2 mentioned in code
Flagged.In.Fence
skipped = "Inside.String.Ignored"
```

```sh
mix usage_rules.list
```

An untagged fence:

```
mix usage_rules.search_docs "Enum.zip"
```
