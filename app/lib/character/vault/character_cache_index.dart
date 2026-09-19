import 'dart:convert';
import 'dart:io';

import 'vault_models.dart';

class CharacterCacheIndex {
  CharacterCacheIndex(this.root);

  final Directory root;
  final Map<String, VaultIndexEntry> _entries = {};

  Map<String, VaultIndexEntry> get entries => Map.unmodifiable(_entries);
  File get file => File('${root.path}${Platform.pathSeparator}index.json');

  Future<void> load() async {
    _entries.clear();
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['entries'] is! List) {
        throw const FormatException('invalid cache index');
      }
      for (final raw in decoded['entries'] as List) {
        if (raw is! Map<String, dynamic>) continue;
        final entry = VaultIndexEntry.fromJson(raw);
        _entries[entry.assetId] = entry;
      }
    } on Object {
      _entries.clear();
      await file.rename(
        '${file.path}.invalid-${DateTime.now().millisecondsSinceEpoch}',
      );
    }
  }

  VaultIndexEntry? operator [](String assetId) => _entries[assetId];

  Future<void> put(VaultIndexEntry entry) async {
    _entries[entry.assetId] = entry;
    await persist();
  }

  Future<void> remove(String assetId) async {
    _entries.remove(assetId);
    await persist();
  }

  Future<void> persist() async {
    await root.create(recursive: true);
    final temp = File('${file.path}.next');
    await temp.writeAsString(
      jsonEncode({
        'schema_version': 1,
        'entries': _entries.values.map((entry) => entry.toJson()).toList(),
      }),
      flush: true,
    );
    final backup = File('${file.path}.previous');
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temp.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }
}
