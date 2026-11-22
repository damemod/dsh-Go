// The `close` effect may only dismiss a panel that owns its own route. The
// mechanism is NativePanelDismissScope: only a standalone panel page / a
// dedicated panel sheet wraps its content in one; panels embedded in a shared
// chat sheet / section / drawer do not, so a close there is ignored rather
// than popping a route the panel does not own (and tearing down its host).
//
// These tests exercise that scope directly: no scope -> no dismiss; a scope
// whose panel owns a route -> dismiss fires; a sibling scope -> each dismiss
// is bound to its own panel and the two never cross-fire. This is the safety
// invariant the `close` effect relies on.

import 'package:dsh_app/ui/plugins/native/native_taps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures the scope visible at this point in the tree.
Widget _probe(void Function(NativePanelDismissScope?) capture) => Builder(
      builder: (context) {
        capture(NativePanelDismissScope.maybeOf(context));
        return const SizedBox.shrink();
      },
    );

void main() {
  testWidgets('close scope absent when a panel is embedded (no own route)', (tester) async {
    NativePanelDismissScope? seen;
    await tester.pumpWidget(
      MaterialApp(home: _probe((scope) => seen = scope)),
    );
    // An embedded panel has no dismiss scope at all -> maybeOf is null ->
    // the CloseEffect case ignores the effect instead of popping the host.
    expect(seen, isNull);
  });

  testWidgets('close scope dismisses only when the panel owns a route', (tester) async {
    var dismissed = 0;
    NativePanelDismissScope? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: NativePanelDismissScope(
          panelId: 'own',
          dismiss: () => dismissed++,
          child: _probe((scope) => seen = scope),
        ),
      ),
    );
    expect(seen, isNotNull);
    expect(seen!.panelId, 'own');
    expect(seen.dismiss, isNotNull);
    seen.dismiss!();
    expect(dismissed, 1);
  });

  testWidgets('close scope with null dismiss is a safe no-op', (tester) async {
    // Defensive path: a scope may exist but deliberately expose no dismiss.
    NativePanelDismissScope? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: NativePanelDismissScope(
          panelId: 'own',
          dismiss: null,
          child: _probe((scope) => seen = scope),
        ),
      ),
    );
    expect(seen, isNotNull);
    expect(seen!.dismiss, isNull);
  });

  testWidgets('a sibling panel scope shadows its host and never cross-fires', (tester) async {
    // Two standalone panels shown together: the inner (tapped) panel's scope
    // shadows the outer one. Calling the resolved dismiss must hit only the
    // inner panel, never the sibling/host route.
    var outerDismissed = 0;
    var innerDismissed = 0;
    NativePanelDismissScope? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: NativePanelDismissScope(
          panelId: 'outer',
          dismiss: () => outerDismissed++,
          child: NativePanelDismissScope(
            panelId: 'inner',
            dismiss: () => innerDismissed++,
            child: _probe((scope) => seen = scope),
          ),
        ),
      ),
    );
    expect(seen, isNotNull);
    expect(seen!.panelId, 'inner');
    seen.dismiss!();
    expect(innerDismissed, 1);
    expect(outerDismissed, 0);
  });
}
