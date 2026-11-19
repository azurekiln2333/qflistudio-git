import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_git_example/main.dart';

void main() {
  /// The form is long, so the test window is taller than the default 800x600.
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const QfliGitExampleApp());
  }

  testWidgets('form shows every input and both buttons', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Remote HTTPS URL'), findsOneWidget);
    expect(find.text('Username (optional)'), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);
    expect(find.text('Author name'), findsOneWidget);
    expect(find.text('Author email'), findsOneWidget);
    expect(find.byKey(const Key('run')), findsOneWidget);
    expect(find.byKey(const Key('cancel')), findsOneWidget);
    expect(find.text('全流程'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('No step has run yet.'), findsOneWidget);
  });

  testWidgets('token field is obscured until toggled', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    TextField tokenField() => tester.widget<TextField>(
      find.widgetWithText(TextField, 'Token'),
    );

    expect(tokenField().obscureText, isTrue);

    await tester.tap(find.byTooltip('Show token'));
    await tester.pump();

    expect(tokenField().obscureText, isFalse);
  });

  testWidgets('cancel button is disabled until a run starts', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    final cancel = tester.widget<OutlinedButton>(
      find.byKey(const Key('cancel')),
    );

    expect(cancel.onPressed, isNull);
  });
}
