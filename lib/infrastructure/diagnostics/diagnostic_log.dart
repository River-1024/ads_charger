import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum DiagnosticKind {
  adapter,
  scan,
  connection,
  profile,
  command,
  timeout,
  disconnect,
  parseFailure,
  verification,
}

class DiagnosticEntry {
  const DiagnosticEntry({
    required this.at,
    required this.kind,
    required this.message,
    this.deviceAlias,
    this.connectionEpoch,
    this.operationId,
  });

  final DateTime at;
  final DiagnosticKind kind;
  final String message;
  final String? deviceAlias;
  final int? connectionEpoch;
  final String? operationId;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toUtc().toIso8601String(),
    'kind': kind.name,
    'message': message,
    if (deviceAlias != null) 'device': deviceAlias,
    if (connectionEpoch != null) 'epoch': connectionEpoch,
    if (operationId != null) 'operationId': operationId,
  };

  String toText() {
    final context = <String>[
      if (deviceAlias != null) 'device=$deviceAlias',
      if (connectionEpoch != null) 'epoch=$connectionEpoch',
      if (operationId != null) 'operation=$operationId',
    ];
    return '${at.toLocal().toIso8601String()} [${kind.name}] $message'
        '${context.isEmpty ? '' : ' (${context.join(', ')})'}';
  }
}

class DiagnosticLog extends ChangeNotifier {
  DiagnosticLog({this.capacity = 250});

  final int capacity;
  final List<DiagnosticEntry> _entries = <DiagnosticEntry>[];

  List<DiagnosticEntry> get entries => List.unmodifiable(_entries);

  void add(
    DiagnosticKind kind,
    String message, {
    String? deviceKey,
    int? connectionEpoch,
    String? operationId,
  }) {
    final entry = DiagnosticEntry(
      at: DateTime.now(),
      kind: kind,
      message: _sanitize(message),
      deviceAlias: deviceKey == null ? null : anonymizeDeviceKey(deviceKey),
      connectionEpoch: connectionEpoch,
      operationId: operationId == null ? null : _sanitize(operationId, max: 48),
    );
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  String exportText() => _entries.map((entry) => entry.toText()).join('\n');

  String exportJson() =>
      const JsonEncoder.withIndent('  ')
          .convert(_entries.map((entry) => entry.toJson()).toList());

  static String anonymizeDeviceKey(String input) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'dev-${hash.toRadixString(16).padLeft(8, '0').substring(0, 8)}';
  }

  static String _sanitize(String input, {int max = 160}) {
    var value = input.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
    value = value.replaceAll(
      RegExp(r'(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}', caseSensitive: false),
      '[device-id]',
    );
    value = value.replaceAll(
      RegExp(
        '[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',
        caseSensitive: false,
      ),
      '[uuid]',
    );
    if (value.length > max) value = value.substring(0, max);
    return value;
  }
}

class DiagnosticExporter {
  const DiagnosticExporter();

  Future<File> download(DiagnosticLog log) async {
    Directory directory;
    try {
      directory =
          await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
    } on UnsupportedError {
      directory = await getApplicationDocumentsDirectory();
    }
    await directory.create(recursive: true);
    final timestamp = DateTime.now().toLocal().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}ads-charger-log-$timestamp.txt',
    );
    await file.writeAsString(log.exportText(), flush: true);
    return file;
  }

  Future<void> share(DiagnosticLog log) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}ads-charger-diagnostics.json',
    );
    await file.writeAsString(log.exportJson(), flush: true);
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: 'application/json')],
          subject: 'ADS 充电器诊断记录',
        ),
      );
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}
