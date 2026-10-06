import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:janus_sip_demo/main.dart';

void main() {
  testWidgets('registration screen displays local Janus URL', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const JanusSipDemoApp());

    expect(find.text('Connect to Janus'), findsOneWidget);
    expect(find.text('Register'), findsOneWidget);

    final janusUrlField = find.byType(TextFormField).first;
    final editableText = tester.widget<EditableText>(
      find.descendant(of: janusUrlField, matching: find.byType(EditableText)),
    );

    expect(editableText.controller.text, 'http://localhost:8088/janus');
  });
}
