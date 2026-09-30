import 'dart:convert';

import '../canon_models.dart';
import '../core/utils.dart';
import 'database.dart';

CanonSource _mapSource(Map<String, Object?> row) => CanonSource(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      title: row['title'] as String,
      fileName: row['file_name'] as String,
      format: row['format'] as String,
      fileUri: row['file_uri'] as String,
      sizeBytes: row['size_bytes'] as int,
      contentHash: row['content_hash'] as String,
      characterCount: row['character_count'] as int,
      coveredUntil: row['covered_until'] as int? ?? 0,
      chunkCount: row['chunk_count'] as int? ?? 0,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

List<String> _parseAliases(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final decoded = json.decode(raw);
    if (decoded is List) return decoded.whereType<String>().map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
  } catch (_) {}
  return const [];
}

CanonEntry _mapEntry(Map<String, Object?> row) => CanonEntry(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      sourceId: row['source_id'] as String,
      category: CanonCategory.fromWire(row['category'] as String),
      title: row['title'] as String,
      summary: row['summary'] as String? ?? '',
      detail: row['detail'] as String? ?? '',
      evidence: row['evidence'] as String? ?? '',
      aliases: _parseAliases(row['aliases']),
      orderIndex: row['order_index'] as int? ?? 0,
      isEnabled: (row['is_enabled'] as int? ?? 1) == 1,
      appliedType: row['applied_type'] as String?,
      appliedId: row['applied_id'] as String?,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

Future<List<CanonSource>> listCanonSources(String projectId) async {
  final db = await getDatabase();
  final rows = await db.query('canon_sources',
      where: 'project_id = ?', whereArgs: [projectId], orderBy: 'updated_at DESC');
  return rows.map(_mapSource).toList();
}

Future<CanonSource?> getCanonSource(String id) async {
  final db = await getDatabase();
  final rows = await db.query('canon_sources', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapSource(rows.first);
}

Future<CanonSource?> findCanonSourceByHash(String projectId, String contentHash) async {
  final db = await getDatabase();
  final rows = await db.query('canon_sources',
      where: 'project_id = ? AND content_hash = ?', whereArgs: [projectId, contentHash], limit: 1);
  return rows.isEmpty ? null : _mapSource(rows.first);
}

Future<CanonSource> createCanonSource({
  required String id,
  required String projectId,
  required String title,
  required String fileName,
  required String format,
  required String fileUri,
  required int sizeBytes,
  required String contentHash,
  required int characterCount,
}) async {
  final db = await getDatabase();
  final now = nowIso();
  await db.insert('canon_sources', {
    'id': id,
    'project_id': projectId,
    'title': requiredText(title, '作品名'),
    'file_name': requiredText(fileName, '文件名'),
    'format': format,
    'file_uri': fileUri,
    'size_bytes': sizeBytes,
    'content_hash': contentHash,
    'character_count': characterCount,
    'covered_until': 0,
    'chunk_count': 0,
    'created_at': now,
    'updated_at': now,
  });
  return CanonSource(
    id: id,
    projectId: projectId,
    title: title.trim(),
    fileName: fileName.trim(),
    format: format,
    fileUri: fileUri,
    sizeBytes: sizeBytes,
    contentHash: contentHash,
    characterCount: characterCount,
    coveredUntil: 0,
    chunkCount: 0,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> updateCanonSourceProgress(
  String id, {
  required int coveredUntil,
  required int chunkCount,
}) async {
  final db = await getDatabase();
  await db.update(
    'canon_sources',
    {'covered_until': coveredUntil, 'chunk_count': chunkCount, 'updated_at': nowIso()},
    where: 'id = ?',
    whereArgs: [id],
  );
}

Future<void> renameCanonSource(String id, String title) async {
  final db = await getDatabase();
  await db.update(
    'canon_sources',
    {'title': requiredText(title, '作品名'), 'updated_at': nowIso()},
    where: 'id = ?',
    whereArgs: [id],
  );
}

Future<void> deleteCanonSource(String id) async {
  final db = await getDatabase();
  await db.delete('canon_sources', where: 'id = ?', whereArgs: [id]);
}

Future<List<CanonEntry>> listCanonEntries(
  String projectId, {
  String? sourceId,
  CanonCategory? category,
  bool enabledOnly = false,
}) async {
  final db = await getDatabase();
  final where = <String>['project_id = ?'];
  final args = <Object?>[projectId];
  if (sourceId != null) {
    where.add('source_id = ?');
    args.add(sourceId);
  }
  if (category != null) {
    where.add('category = ?');
    args.add(category.wire);
  }
  if (enabledOnly) where.add('is_enabled = 1');
  final rows = await db.query(
    'canon_entries',
    where: where.join(' AND '),
    whereArgs: args,
    orderBy: 'category, order_index, created_at',
  );
  return rows.map(_mapEntry).toList();
}

Future<CanonEntry?> getCanonEntry(String id) async {
  final db = await getDatabase();
  final rows = await db.query('canon_entries', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapEntry(rows.first);
}

Future<CanonEntry?> findCanonEntryByTitle({
  required String sourceId,
  required CanonCategory category,
  required String title,
}) async {
  final db = await getDatabase();
  final rows = await db.query(
    'canon_entries',
    where: 'source_id = ? AND category = ? AND LOWER(title) = ?',
    whereArgs: [sourceId, category.wire, title.trim().toLowerCase()],
    limit: 1,
  );
  return rows.isEmpty ? null : _mapEntry(rows.first);
}

/// 按标题或别名查找同一实体，用于分片蒸馏时把不同称呼归并到同一张卡。
Future<CanonEntry?> findCanonEntryByName({
  required String sourceId,
  required CanonCategory category,
  required String name,
}) async {
  final key = name.trim().toLowerCase();
  if (key.isEmpty) return null;
  final db = await getDatabase();
  final rows = await db.query(
    'canon_entries',
    where: 'source_id = ? AND category = ?',
    whereArgs: [sourceId, category.wire],
  );
  for (final row in rows) {
    final entry = _mapEntry(row);
    if (entry.nameKeys.contains(key)) return entry;
  }
  return null;
}

/// 把若干条目合并进目标条目：合并摘要/详情/依据，并把来源标题与别名登记为目标别名。
Future<CanonEntry> mergeCanonEntries({
  required String targetId,
  required List<String> sourceIds,
}) async {
  final db = await getDatabase();
  final targetRows = await db.query('canon_entries', where: 'id = ?', whereArgs: [targetId], limit: 1);
  if (targetRows.isEmpty) throw Exception('目标条目不存在');
  final target = _mapEntry(targetRows.first);
  final sources = <CanonEntry>[];
  for (final id in sourceIds) {
    if (id == targetId) continue;
    final rows = await db.query('canon_entries', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty) sources.add(_mapEntry(rows.first));
  }
  if (sources.isEmpty) return target;

  final detailParts = <String>[];
  void addPart(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return;
    final probe = trimmed.replaceAll(RegExp(r'\s+'), '');
    for (final existing in detailParts) {
      if (existing.replaceAll(RegExp(r'\s+'), '').contains(probe.length > 30 ? probe.substring(0, 30) : probe)) {
        return;
      }
    }
    detailParts.add(trimmed);
  }

  addPart(target.detail);
  final aliases = <String>{...target.aliases};
  final summaryParts = <String>[];
  if (target.summary.trim().isNotEmpty) summaryParts.add(target.summary.trim());
  final evidenceParts = <String>[];
  if (target.evidence.trim().isNotEmpty) evidenceParts.add(target.evidence.trim());
  for (final source in sources) {
    addPart(source.detail);
    aliases.add(source.title);
    aliases.addAll(source.aliases);
    if (source.summary.trim().isNotEmpty &&
        !summaryParts.any((item) => item.toLowerCase() == source.summary.trim().toLowerCase())) {
      summaryParts.add(source.summary.trim());
    }
    if (source.evidence.trim().isNotEmpty &&
        !evidenceParts.any((item) => item.toLowerCase() == source.evidence.trim().toLowerCase())) {
      evidenceParts.add(source.evidence.trim());
    }
  }
  aliases.removeWhere((alias) => alias.trim().toLowerCase() == target.title.trim().toLowerCase());

  await db.transaction((txn) async {
    await txn.update(
      'canon_entries',
      {
        'summary': summaryParts.join('；'),
        'detail': detailParts.join('\n\n'),
        'evidence': evidenceParts.join(' / '),
        'aliases': json.encode(_normalizeAliases(aliases.toList())),
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [targetId],
    );
    for (final source in sources) {
      await txn.delete('canon_entries', where: 'id = ?', whereArgs: [source.id]);
    }
  });
  final updated = await db.query('canon_entries', where: 'id = ?', whereArgs: [targetId], limit: 1);
  return _mapEntry(updated.first);
}

/// 供蒸馏提示复用已存在的规范名称与别名。
Future<List<({String title, List<String> aliases})>> listCanonNamesForSource(String sourceId) async {
  final db = await getDatabase();
  final rows = await db.query('canon_entries', where: 'source_id = ?', whereArgs: [sourceId]);
  return rows.map((row) {
    final entry = _mapEntry(row);
    return (title: entry.title, aliases: entry.aliases);
  }).toList();
}

Future<CanonEntry> createCanonEntry({
  required String projectId,
  required String sourceId,
  required CanonCategory category,
  required String title,
  String summary = '',
  String detail = '',
  String evidence = '',
  List<String> aliases = const [],
  int? orderIndex,
}) async {
  final db = await getDatabase();
  final id = createId();
  final now = nowIso();
  var order = orderIndex;
  if (order == null) {
    final row = await db.rawQuery(
      'SELECT COALESCE(MAX(order_index), -1) + 1 AS next_order FROM canon_entries '
      'WHERE source_id = ? AND category = ?',
      [sourceId, category.wire],
    );
    order = (row.first['next_order'] as num?)?.toInt() ?? 0;
  }
  await db.insert('canon_entries', {
    'id': id,
    'project_id': projectId,
    'source_id': sourceId,
    'category': category.wire,
    'title': title.trim(),
    'summary': summary.trim(),
    'detail': detail.trim(),
    'evidence': evidence.trim(),
    'aliases': json.encode(_normalizeAliases(aliases)),
    'order_index': order,
    'is_enabled': 1,
    'applied_type': null,
    'applied_id': null,
    'created_at': now,
    'updated_at': now,
  });
  return CanonEntry(
    id: id,
    projectId: projectId,
    sourceId: sourceId,
    category: category,
    title: title.trim(),
    summary: summary.trim(),
    detail: detail.trim(),
    evidence: evidence.trim(),
    aliases: _normalizeAliases(aliases),
    orderIndex: order,
    isEnabled: true,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> updateCanonEntry(
  String id, {
  CanonCategory? category,
  String? title,
  String? summary,
  String? detail,
  String? evidence,
  List<String>? aliases,
  bool? isEnabled,
}) async {
  final db = await getDatabase();
  final values = <String, Object?>{'updated_at': nowIso()};
  if (category != null) values['category'] = category.wire;
  if (title != null) values['title'] = title.trim();
  if (summary != null) values['summary'] = summary.trim();
  if (detail != null) values['detail'] = detail.trim();
  if (evidence != null) values['evidence'] = evidence.trim();
  if (aliases != null) values['aliases'] = json.encode(_normalizeAliases(aliases));
  if (isEnabled != null) values['is_enabled'] = isEnabled ? 1 : 0;
  await db.update('canon_entries', values, where: 'id = ?', whereArgs: [id]);
}

List<String> _normalizeAliases(List<String> aliases) {
  final seen = <String>{};
  final result = <String>[];
  for (final alias in aliases) {
    final trimmed = alias.trim();
    final key = trimmed.toLowerCase();
    if (trimmed.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    result.add(trimmed);
  }
  return result;
}

Future<void> markCanonEntryApplied(String id, String appliedType, String appliedId) async {
  final db = await getDatabase();
  await db.update(
    'canon_entries',
    {'applied_type': appliedType, 'applied_id': appliedId, 'updated_at': nowIso()},
    where: 'id = ?',
    whereArgs: [id],
  );
}

Future<void> deleteCanonEntry(String id) async {
  final db = await getDatabase();
  await db.delete('canon_entries', where: 'id = ?', whereArgs: [id]);
}

Future<void> deleteCanonEntriesForSource(String sourceId) async {
  final db = await getDatabase();
  await db.delete('canon_entries', where: 'source_id = ?', whereArgs: [sourceId]);
}

Future<int> countCanonEntries(String projectId) async {
  final db = await getDatabase();
  final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM canon_entries WHERE project_id = ?', [projectId]);
  return (rows.first['total'] as num?)?.toInt() ?? 0;
}