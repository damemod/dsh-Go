# Declarative example plugin

One plugin brings four declarative capabilities together:

- **Static effects**: the `write-list` capsule declares an `insert` effect in the manifest; the app runs it without host code. `insert-tool` does the same for a plus-panel tool.
- **Deferred result**: `polish-list` answers "正在润色" at once, then inserts the tidied text into the composer; it can be cancelled.
- **Tool result card**: the `declarative_checklist` tool returns a `dsh-go/view` through `presentationMeta`; the app draws the checklist as a native card.
- **Several seats combined**: capsule, status strip, plus-panel tool, chat action, turn note and two panels all live in this one plugin.

The manifest, views and effects stay within the framework's published limits; the framework, bridge, SDK and golden files are unchanged.

```sh
dsh plugin --profile web add /absolute/path/to/examples/plugins/dsh-go-example-declarative
```

Self-check:

```sh
npm test
npm run check -- --load --lang zh
```

Tests run on `sdk/plugin-kit`'s test host and cover manifest validation, all six seats, static effects, deferred result completion and cancellation, strip and turn-note feeds, panel view budgets, the tool card, a bridge-less host and rejection of a broken manifest.

MIT © DSH-TUI (ccch1mneyyy).
