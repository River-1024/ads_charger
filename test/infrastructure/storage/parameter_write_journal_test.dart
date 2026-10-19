import 'dart:io';

import 'package:ads_charger/infrastructure/storage/parameter_write_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'parameter-journal-test-',
    );
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('writes with a temporary file and recovers the durable entry', () async {
    final journal = await ParameterWriteJournal.create(
      directory: directory,
      now: () => DateTime.utc(2026, 9, 14, 12),
    );
    final entry = ParameterWriteJournalEntry(
      operationId: 'operation-1',
      targetDeviceKey: 'device-1',
      profileFingerprint: 'profile-1',
      targetVoltageHundredthsVolts: 5460,
      targetCurrentTenthsAmps: 125,
      stage: ParameterWriteStage.prepared,
      updatedAt: DateTime.utc(2026, 9, 14, 11, 59),
    );

    await journal.write(entry);

    final files = await directory.list().toList();
    expect(files.map((file) => file.path), [
      '${directory.path}${Platform.pathSeparator}${ParameterWriteJournal.fileName}',
    ]);
    final recovered = await journal.recover();
    expect(recovered?.operationId, 'operation-1');
    expect(recovered?.targetDeviceKey, 'device-1');
    expect(recovered?.profileFingerprint, 'profile-1');
    expect(recovered?.targetVoltageHundredthsVolts, 5460);
    expect(recovered?.targetCurrentTenthsAmps, 125);
    expect(recovered?.stage, ParameterWriteStage.prepared);
    expect(recovered?.updatedAt, DateTime.utc(2026, 9, 14, 11, 59));
  });

  test('atomically replaces an earlier stage and can be cleared', () async {
    var tick = 0;
    final journal = await ParameterWriteJournal.create(
      directory: directory,
      now: () => DateTime.utc(2026, 9, 14, 12, 0, tick++),
    );

    await journal.write(_entry(stage: ParameterWriteStage.prepared));
    await journal.write(_entry(stage: ParameterWriteStage.writing));

    expect((await journal.recover())?.stage, ParameterWriteStage.writing);

    await journal.clear();
    expect(await journal.recover(), isNull);
    await journal.clear();
  });

  test('damaged journal data is ignored and removed', () async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${ParameterWriteJournal.fileName}',
    );
    await file.writeAsString('{"operationId":');
    final journal = await ParameterWriteJournal.create(directory: directory);

    expect(await journal.recover(), isNull);
    expect(await file.exists(), isFalse);
  });

  test('well-formed but invalid journal data is ignored and removed', () async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${ParameterWriteJournal.fileName}',
    );
    await file.writeAsString(
      '{"version":1,"operationId":"","stage":"unknown"}',
    );
    final journal = await ParameterWriteJournal.create(directory: directory);

    expect(await journal.recover(), isNull);
    expect(await file.exists(), isFalse);
  });
}

ParameterWriteJournalEntry _entry({required ParameterWriteStage stage}) {
  return ParameterWriteJournalEntry(
    operationId: 'operation-1',
    targetDeviceKey: 'device-1',
    profileFingerprint: 'profile-1',
    targetVoltageHundredthsVolts: 5460,
    targetCurrentTenthsAmps: 125,
    stage: stage,
    updatedAt: DateTime.utc(2026, 9, 14, 12),
  );
}
