# Fixture rules

Good module refs: `Enum`, `Enum.map/2`, `Mix.Tasks.UsageRules.List`, `UsageRules.Validator`.

Bad module refs: `NoSuch.Module.Xyz`, `NoSuchModuleAnywhere`.

Good function refs: `String.upcase/1`, `GenServer.handle_call/3` (behaviour callback), `:timer.tc/3`.

Bad function refs: `Enum.definitely_not_real/2`, `Enum.map/9`, `:timer.definitely_not_real/1`, `:no_such_erlang_module.foo/1`.

Good mix task: `mix usage_rules.docs`. Bad mix task: `mix definitely_not_a_real_task`.

Capitalized file names in spans are not module refs: `AGENTS.md`, `SKILL.md`, `mix.exs`.

Links: [good](exists.md), [broken](missing.md), [anchor](#section), [remote](https://hexdocs.pm/elixir), [absolute](/etc/hosts).

```elixir
String.upcase("hello") # comment with `Skipped.Module`
Flagged.In.Fence
:timer.tc(fn -> :ok end)
```

```sh
mix usage_rules.list
```

An untagged fence:

```
mix usage_rules.search_docs "Enum.zip"
```
