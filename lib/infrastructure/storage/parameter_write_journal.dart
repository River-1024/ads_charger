import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum ParameterWriteStage { prepared, writing, applied, verified }

final class ParameterWriteJournalEntry {
  const ParameterWriteJournalEntry({
    required this.operationId,
    required this.targetDeviceKey,
    required this.profileFingerprint,
    required this.targetVoltageHundredthsVolts,
    required this.targetCurrentTenthsAmps,
    required this.stage,
    required this.updatedAt,
  });

  final String operationId;
  final String targetDeviceKey;
  final String profileFingerprint;
  final int targetVoltageHundredthsVolts;
  final int targetCurrentTenthsAmps;
  final ParameterWriteStage stage;
  final DateTime updatedAt;

  Map<String, Object> toJson() => <String, Object>{
    'version': 1,
    'operationId': operationId,
    'targetDeviceKey': targetDeviceKey,
    'profileFingerprint': profileFingerprint,
    'targetVoltageHundredthsVolts': targetVoltageHundredthsVolts,
    'targetCurrentTenthsAmps': targetCurrentTenthsAmps,
    'stage': stage.name,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static ParameterWriteJournalEntry? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      return null;
    }

    final operationId = _nonEmptyString(value['operationId']);
    final targetDeviceKey = _nonEmptyString(value['targetDeviceKey']);
    final profileFingerprint = _nonEmptyString(value['profileFingerprint']);
    final voltage = value['targetVoltageHundredthsVolts'];
    final current = value['targetCurrentTenthsAmps'];
    final stageName = value['stage'];
    final updatedAtText = value['updatedAt'];
    final stage = stageName is String
        ? ParameterWriteStage.values
              .where((candidate) => candidate.name == stageName)
              .firstOrNull
        : null;
    final updatedAt = updatedAtText is String
        ? DateTime.tryParse(updatedAtText)?.toUtc()
        : null;

    if (operationId == null ||
        targetDeviceKey == null ||
        profileFingerprint == null ||
        voltage is! int ||
        current is! int ||
        voltage < 0 ||
        current < 0 ||
        stage == null ||
        updatedAt == null) {
      return null;
    }

    return ParameterWriteJournalEntry(
      operationId: operationId,
      targetDeviceKey: targetDeviceKey,
      profileFingerprint: profileFingerprint,
      targetVoltageHundredthsVolts: voltage,
      targetCurrentTenthsAmps: current,
      stage: stage,
      updatedAt: updatedAt,
    );
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return value;
  }
}

final class ParameterWriteJournal {
  ParameterWriteJournal._(this._directory, this._now);

  static const String fileName = 'parameter_write_journal.json';

  final Directory _directory;
  final DateTime Function() _now;

  static Future<ParameterWriteJournal> create({
    Directory? directory,
    DateTime Function()? now,
  }) async {
    final resolvedDirectory =
        directory ?? await getApplicationSupportDirectory();
    return ParameterWriteJournal._(resolvedDirectory, now ?? DateTime.now);
  }

  File get _journalFile =>
      File('${_directory.path}${Platform.pathSeparator}$fileName');

  Future<void> write(ParameterWriteJournalEntry entry) async {
    await _directory.create(recursive: true);
    final target = _journalFile;
    final temporary = File(
      '${target.path}.tmp-${_now().toUtc().microsecondsSinceEpoch}',
    );

    try {
      await temporary.writeAsString(
        jsonEncode(entry.toJson()),
        encoding: utf8,
        flush: true,
      );
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<ParameterWriteJournalEntry?> recover() async {
    final file = _journalFile;
    if (!await file.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await file.readAsString(encoding: utf8));
      final entry = ParameterWriteJournalEntry.tryFromJson(decoded);
      if (entry != null) {
        return entry;
      }
    } on FormatException {
      // Treat truncated or otherwise corrupt journal data as unrecoverable.
    } on FileSystemException {
      return null;
    }

    await _deleteIfPresent(file);
    return null;
  }

  Future<void> clear() => _deleteIfPresent(_journalFile);

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // A concurrent clear/recovery may already have removed the file.
    }
  }
}
