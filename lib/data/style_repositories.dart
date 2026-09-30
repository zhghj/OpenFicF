import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/utils.dart';
import '../models.dart';
import 'database.dart';

const int maxStyleGuideCharacters = 100000;
const String activeStyleKeyPrefix = 'style.activeProfile.';
const String activeStyleListKeyPrefix = 'style.activeProfiles.';
const String noStyleProfileValue = '__none__';

class ActiveStyleSelection {
  final bool configured;
  final StyleProfile? profile;

  const ActiveStyleSelection({required this.configured, required this.profile});
}

StyleSource _mapStyleSource(Map<String, Object?> row) => StyleSource(
      id: row['id'] as String,
      title: row['title'] as String,
      fileName: row['file_name'] as String,
      format: row['format'] as String,
      fileUri: row['file_uri'] as String,
      sizeBytes: row['size_bytes'] as int,
      contentHash: row['content_hash'] as String,
      characterCount: row['character_count'] as int,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

StyleProfile _mapStyleProfile(Map<String, Object?> row) => StyleProfile(
      id: row['id'] as String,
      seriesId: row['series_id'] as String,
      projectId: row['project_id'] as String?,
      sourceId: row['source_id'] as String?,
      kind: StyleProfileKind.fromWire(row['kind'] as String),
      name: row['name'] as String,
      version: row['version'] as int,
      guide: row['guide'] as String,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

String _requiredText(String value, String label) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw Exception('$label不能为空');
  return normalized;
}

Future<void> _upsertSetting(DatabaseExecutor db, String key, String value) async {
  final updated =
      await db.update('app_settings', {'value': value}, where: 'key = ?', whereArgs: [key]);
  if (updated == 0) {
    await db.insert('app_settings', {'key': key, 'value': value});
  }
}

Future<List<StyleSource>> listStyleSources() async {
  final database = await getDatabase();
  final rows = await database
      .query('style_sources', orderBy: 'updated_at DESC, created_at DESC');
  return rows.map(_mapStyleSource).toList();
}

Future<StyleSource?> getStyleSource(String id) async {
  final database = await getDatabase();
  final rows =
      await database.query('style_sources', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapStyleSource(rows.first);
}

Future<StyleSource?> findStyleSourceByHash(String contentHash) async {
  final database = await getDatabase();
  final rows = await database
      .query('style_sources', where: 'content_hash = ?', whereArgs: [contentHash], limit: 1);
  return rows.isEmpty ? null : _mapStyleSource(rows.first);
}

Future<StyleSource> createStyleSource({
  required String id,
  required String title,
  required String fileName,
  required String format,
  required String fileUri,
  required int sizeBytes,
  required String contentHash,
  required int characterCount,
}) async {
  final database = await getDatabase();
  final now = nowIso();
  var normalizedTitle = _requiredText(title, '书名');
  if (normalizedTitle.length > 200) normalizedTitle = normalizedTitle.substring(0, 200);
  var normalizedFileName = _requiredText(fileName, '文件名');
  if (normalizedFileName.length > 500) normalizedFileName = normalizedFileName.substring(0, 500);
  if (!['txt', 'markdown', 'epub'].contains(format)) throw Exception('不支持的书籍格式');
  if (sizeBytes < 1) throw Exception('书籍文件大小无效');
  if (characterCount < 1) throw Exception('书籍正文为空');
  await database.insert('style_sources', {
    'id': id,
    'title': normalizedTitle,
    'file_name': normalizedFileName,
    'format': format,
    'file_uri': fileUri,
    'size_bytes': sizeBytes,
    'content_hash': _requiredText(contentHash, '文件摘要'),
    'character_count': characterCount,
    'created_at': now,
    'updated_at': now,
  });
  return StyleSource(
    id: id,
    title: normalizedTitle,
    fileName: normalizedFileName,
    format: format,
    fileUri: fileUri,
    sizeBytes: sizeBytes,
    contentHash: contentHash,
    characterCount: characterCount,
    createdAt: now,
    updatedAt: now,
  );
}

Future<StyleSource> renameStyleSource(String id, String title) async {
  final database = await getDatabase();
  final rows =
      await database.query('style_sources', where: 'id = ?', whereArgs: [id], limit: 1);
  if (rows.isEmpty) throw Exception('参考书不存在');
  var normalizedTitle = _requiredText(title, '书名');
  if (normalizedTitle.length > 200) normalizedTitle = normalizedTitle.substring(0, 200);
  final updatedAt = nowIso();
  await database.update('style_sources', {'title': normalizedTitle, 'updated_at': updatedAt},
      where: 'id = ?', whereArgs: [id]);
  final source = _mapStyleSource(rows.first);
  return StyleSource(
    id: source.id,
    title: normalizedTitle,
    fileName: source.fileName,
    format: source.format,
    fileUri: source.fileUri,
    sizeBytes: source.sizeBytes,
    contentHash: source.contentHash,
    characterCount: source.characterCount,
    createdAt: source.createdAt,
    updatedAt: updatedAt,
  );
}

Future<void> deleteStyleSourceRecord(String id) async {
  final database = await getDatabase();
  await database.transaction((transaction) async {
    await transaction.rawDelete(
      'DELETE FROM app_settings WHERE key LIKE ? AND value IN '
      '(SELECT id FROM style_profiles WHERE source_id = ?)',
      ['$activeStyleKeyPrefix%', id],
    );
    await transaction.delete('style_sources', where: 'id = ?', whereArgs: [id]);
  });
}

Future<List<StyleProfile>> listStyleProfiles(String projectId) async {
  final database = await getDatabase();
  final rows = await database.rawQuery('''
    SELECT * FROM style_profiles
    WHERE kind = 'reference' OR (kind = 'author' AND project_id = ?)
    ORDER BY CASE kind WHEN 'author' THEN 0 ELSE 1 END, updated_at DESC, version DESC
  ''', [projectId]);
  return rows.map(_mapStyleProfile).toList();
}

Future<List<StyleProfile>> listStyleProfilesForSource(String sourceId) async {
  final database = await getDatabase();
  final rows = await database.query('style_profiles',
      where: 'source_id = ?', whereArgs: [sourceId], orderBy: 'version DESC');
  return rows.map(_mapStyleProfile).toList();
}

Future<StyleProfile?> getStyleProfile(String id) async {
  final database = await getDatabase();
  final rows =
      await database.query('style_profiles', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapStyleProfile(rows.first);
}

Future<StyleProfile?> getLatestAuthorStyleProfile(String projectId) async {
  final database = await getDatabase();
  final rows = await database.rawQuery('''
    SELECT * FROM style_profiles
    WHERE kind = 'author' AND project_id = ?
    ORDER BY version DESC, updated_at DESC LIMIT 1
  ''', [projectId]);
  return rows.isEmpty ? null : _mapStyleProfile(rows.first);
}

Future<StyleProfile> createStyleProfileVersion({
  String? projectId,
  String? sourceId,
  required StyleProfileKind kind,
  required String name,
  required String guide,
  String? seriesId,
  String? activateForProjectId,
}) async {
  final database = await getDatabase();
  final normalizedGuide = _requiredText(guide, '文风指南');
  if (normalizedGuide.length > maxStyleGuideCharacters) {
    throw Exception('文风指南超过 $maxStyleGuideCharacters 字符限制');
  }
  final normalizedProjectId = (projectId?.trim().isEmpty ?? true) ? null : projectId!.trim();
  final normalizedSourceId = (sourceId?.trim().isEmpty ?? true) ? null : sourceId!.trim();
  if (kind == StyleProfileKind.author && (normalizedProjectId == null || normalizedSourceId != null)) {
    throw Exception('作者文风必须绑定作品且不能绑定参考书');
  }
  if (kind == StyleProfileKind.reference && (normalizedSourceId == null || normalizedProjectId != null)) {
    throw Exception('参考文风必须绑定参考书且不能绑定作品');
  }
  final normalizedSeriesId = (seriesId?.trim().isNotEmpty ?? false)
      ? seriesId!.trim()
      : (kind == StyleProfileKind.author ? 'author-$normalizedProjectId' : 'reference-$normalizedSourceId');
  var normalizedName = _requiredText(name, '文风名称');
  if (normalizedName.length > 200) normalizedName = normalizedName.substring(0, 200);
  final now = nowIso();
  StyleProfile? profile;
  await database.transaction((transaction) async {
    if (normalizedProjectId != null) {
      final project = await transaction.query('projects',
          columns: ['id'], where: 'id = ?', whereArgs: [normalizedProjectId], limit: 1);
      if (project.isEmpty) throw Exception('作品不存在');
    }
    if (normalizedSourceId != null) {
      final source = await transaction.query('style_sources',
          columns: ['id'], where: 'id = ?', whereArgs: [normalizedSourceId], limit: 1);
      if (source.isEmpty) throw Exception('参考书不存在');
    }
    final latest = await transaction.rawQuery(
      'SELECT * FROM style_profiles WHERE series_id = ? ORDER BY version DESC LIMIT 1',
      [normalizedSeriesId],
    );
    if (latest.isNotEmpty && (latest.first['guide'] as String).trim() == normalizedGuide) {
      profile = _mapStyleProfile(latest.first);
    } else {
      final id = createId();
      final version = latest.isEmpty ? 1 : ((latest.first['version'] as int) + 1);
      await transaction.insert('style_profiles', {
        'id': id,
        'series_id': normalizedSeriesId,
        'project_id': normalizedProjectId,
        'source_id': normalizedSourceId,
        'kind': kind.wire,
        'name': normalizedName,
        'version': version,
        'guide': normalizedGuide,
        'created_at': now,
        'updated_at': now,
      });
      profile = StyleProfile(
        id: id,
        seriesId: normalizedSeriesId,
        projectId: normalizedProjectId,
        sourceId: normalizedSourceId,
        kind: kind,
        name: normalizedName,
        version: version,
        guide: normalizedGuide,
        createdAt: now,
        updatedAt: now,
      );
    }
    final activateProjectId = (activateForProjectId?.trim().isEmpty ?? true)
        ? null
        : activateForProjectId!.trim();
    if (activateProjectId != null && profile != null) {
      final allowed = profile!.kind == StyleProfileKind.reference ||
          profile!.projectId == activateProjectId;
      if (!allowed) throw Exception('该作者文风不属于当前作品');
      await _upsertSetting(transaction, '$activeStyleKeyPrefix$activateProjectId', profile!.id);
    }
  });
  if (profile == null) throw Exception('文风版本保存失败');
  return profile!;
}

Future<void> deleteStyleProfile(String id) async {
  final database = await getDatabase();
  await database.transaction((transaction) async {
    final profile = await transaction.query('style_profiles',
        columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (profile.isEmpty) throw Exception('文风版本不存在');
    await transaction.rawDelete(
      'DELETE FROM app_settings WHERE key LIKE ? AND value = ?',
      ['$activeStyleKeyPrefix%', id],
    );
    await transaction.delete('style_profiles', where: 'id = ?', whereArgs: [id]);
  });
}

/// 当前作品启用的全部文风（可同时启用多本参考文风 + 作者文风）。
Future<List<StyleProfile>> getActiveStyleProfiles(String projectId) async {
  final database = await getDatabase();
  final listKey = '$activeStyleListKeyPrefix$projectId';
  final rows = await database.query('app_settings',
      columns: ['value'], where: 'key = ?', whereArgs: [listKey], limit: 1);
  var ids = <String>[];
  if (rows.isNotEmpty) {
    final raw = rows.first['value'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) ids = decoded.whereType<String>().toList();
      } catch (_) {}
    }
  } else {
    // 兼容旧的单选键并迁移到多选键。
    final legacyKey = '$activeStyleKeyPrefix$projectId';
    final legacy = await database.query('app_settings',
        columns: ['value'], where: 'key = ?', whereArgs: [legacyKey], limit: 1);
    final value = legacy.isEmpty ? null : legacy.first['value'] as String?;
    if (value != null && value.isNotEmpty && value != noStyleProfileValue) ids = [value];
    if (value != null && value.isNotEmpty) {
      await _upsertSetting(database, listKey, jsonEncode(ids));
    }
  }
  if (ids.isEmpty) return [];
  final result = <StyleProfile>[];
  for (final id in ids) {
    final profileRows = await database.rawQuery(
      "SELECT * FROM style_profiles WHERE id = ? AND (kind = 'reference' OR project_id = ?)",
      [id, projectId],
    );
    if (profileRows.isNotEmpty) result.add(_mapStyleProfile(profileRows.first));
  }
  if (result.length != ids.length) {
    await _upsertSetting(database, listKey, jsonEncode(result.map((profile) => profile.id).toList()));
  }
  return result;
}

Future<void> setActiveStyleProfiles(String projectId, List<String> profileIds) async {
  final database = await getDatabase();
  final listKey = '$activeStyleListKeyPrefix$projectId';
  final valid = <String>[];
  final seen = <String>{};
  for (final id in profileIds) {
    if (id.isEmpty || seen.contains(id)) continue;
    final rows = await database.rawQuery(
      "SELECT id FROM style_profiles WHERE id = ? AND (kind = 'reference' OR project_id = ?)",
      [id, projectId],
    );
    if (rows.isNotEmpty) {
      valid.add(id);
      seen.add(id);
    }
  }
  await _upsertSetting(database, listKey, jsonEncode(valid));
  // 同步旧的单选键以兼容其它读取点。
  await _upsertSetting(
      database, '$activeStyleKeyPrefix$projectId', valid.isEmpty ? noStyleProfileValue : valid.first);
}

Future<void> toggleActiveStyleProfile(String projectId, String profileId, bool enabled) async {
  final current = await getActiveStyleProfiles(projectId);
  final ids = current.map((profile) => profile.id).toList();
  if (enabled) {
    if (!ids.contains(profileId)) ids.add(profileId);
  } else {
    ids.remove(profileId);
  }
  await setActiveStyleProfiles(projectId, ids);
}

Future<bool> isStyleSelectionConfigured(String projectId) async {
  final database = await getDatabase();
  final rows = await database.query('app_settings',
      columns: ['key'],
      where: 'key IN (?, ?)',
      whereArgs: ['$activeStyleListKeyPrefix$projectId', '$activeStyleKeyPrefix$projectId']);
  return rows.isNotEmpty;
}

Future<ActiveStyleSelection> getActiveStyleSelection(String projectId) async {
  final profiles = await getActiveStyleProfiles(projectId);
  return ActiveStyleSelection(
    configured: await isStyleSelectionConfigured(projectId),
    profile: profiles.isEmpty ? null : profiles.first,
  );
}

Future<StyleProfile?> getActiveStyleProfile(String projectId) async {
  return (await getActiveStyleSelection(projectId)).profile;
}

Future<void> setActiveStyleProfile(String projectId, String? profileId) async {
  if (profileId == null || profileId.isEmpty) {
    await setActiveStyleProfiles(projectId, const []);
    return;
  }
  await setActiveStyleProfiles(projectId, [profileId]);
}