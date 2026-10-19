import 'package:ads_charger/infrastructure/diagnostics/diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostics sanitize identifiers and cap entries', () {
    final log = DiagnosticLog(capacity: 2);
    log.add(DiagnosticKind.scan, 'name\u0000 AA:BB:CC:DD:EE:FF');
    log.add(
      DiagnosticKind.profile,
      'service 123e4567-e89b-12d3-a456-426614174000',
      deviceKey: 'AA:BB:CC:DD:EE:FF',
    );
    log.add(DiagnosticKind.timeout, 'query 02 timeout');

    expect(log.entries, hasLength(2));
    final exported = log.exportJson();
    expect(exported, isNot(contains('AA:BB:CC:DD:EE:FF')));
    expect(exported, isNot(contains('123e4567-e89b-12d3-a456-426614174000')));
    expect(exported, contains('[uuid]'));
    expect(exported, contains('dev-'));
  });

  test('text export preserves order and clear notifies listeners', () {
    final log = DiagnosticLog();
    var changes = 0;
    log.addListener(() => changes += 1);

    log.add(DiagnosticKind.scan, 'first AA:BB:CC:DD:EE:FF');
    log.add(DiagnosticKind.connection, 'second');

    final text = log.exportText();
    expect(text.indexOf('first'), lessThan(text.indexOf('second')));
    expect(text, isNot(contains('AA:BB:CC:DD:EE:FF')));
    expect(changes, 2);

    log.clear();
    expect(log.entries, isEmpty);
    expect(changes, 3);
  });
}
