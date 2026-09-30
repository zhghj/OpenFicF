import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/utils.dart';
import '../llm/limits.dart';
import '../models.dart';
import '../services/secure_store.dart';
import 'database.dart';

const int maxEditorContentCharacters = 100000;
const int maxEditorContentLines = 2000;

// ---------------------------------------------------------------------------
// 映射
// ---------------------------------------------------------------------------

Project _mapProject(Map<String, Object?> row) => Project(
      id: row['id'] as String,
      title: row['title'] as String,
      description: row['description'] as String? ?? '',
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

Volume _mapVolume(Map<String, Object?> row) => Volume(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      title: row['title'] as String,
      orderIndex: row['order_index'] as int,
    );

Chapter _mapChapter(Map<String, Object?> row) => Chapter(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      volumeId: row['volume_id'] as String,
      title: row['title'] as String,
      content: row['content'] as String? ?? '',
      orderIndex: row['order_index'] as int,
      updatedAt: row['updated_at'] as String,
    );

Provider _mapProvider(Map<String, Object?> row) => Provider(
      id: row['id'] as String,
      name: row['name'] as String,
      type: ProviderType.fromWire(row['type'] as String),
      baseUrl: row['base_url'] as String,
      apiKeyRef: row['api_key_ref'] as String,
      createdAt: row['created_at'] as String,
    );

LlmModel _mapModel(Map<String, Object?> row) => LlmModel(
      id: row['id'] as String,
      providerId: row['provider_id'] as String,
      name: row['name'] as String,
      modelId: row['model_id'] as String,
      temperature: (row['temperature'] as num).toDouble(),
      maxTokens: row['max_tokens'] as int,
    );

ChatSession _mapSession(Map<String, Object?> row) => ChatSession(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      title: row['title'] as String,
      modelId: row['model_id'] as String?,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

ChatMessage _mapMessage(Map<String, Object?> row) => ChatMessage(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      sessionId: row['session_id'] as String,
      role: row['role'] as String,
      content: row['content'] as String,
      metadata: _parseMetadata(row['metadata_json'] as String?),
      createdAt: row['created_at'] as String,
    );

ChatMessageMetadata? _parseMetadata(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    final decoded = jsonDecodeMap(value);
    if (decoded == null) return null;
    return ChatMessageMetadata.fromJson(decoded);
  } catch (_) {
    return null;
  }
}

Character _mapCharacter(Map<String, Object?> row) => Character(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      name: row['name'] as String,
      description: row['description'] as String? ?? '',
      imagePath: row['image_path'] as String?,
      isFavorited: (row['is_favorited'] as int? ?? 0) == 1,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

WorldInfo _mapWorldInfo(Map<String, Object?> row) => WorldInfo(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      name: row['name'] as String,
      description: row['description'] as String? ?? '',
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

WorldInfoEntry _mapWorldEntry(Map<String, Object?> row) => WorldInfoEntry(
      id: row['id'] as String,
      worldInfoId: row['world_info_id'] as String,
      uid: row['uid'] as int,
      name: row['name'] as String,
      order: row['entry_order'] as int,
      content: row['content'] as String? ?? '',
      tokenCount: row['token_count'] as int? ?? 0,
      isEnabled: (row['is_enabled'] as int? ?? 1) == 1,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

void _validateChapterContent(String content) {
  final lineCount = content.split(RegExp(r'\r?\n')).length;
  if (content.length > maxEditorContentCharacters || lineCount > maxEditorContentLines) {
    throw Exception(
      '内容超出限制：单一章节最多 $maxEditorContentLines 行或 $maxEditorContentCharacters 字符',
    );
  }
}

String _generatedMessageTitle(String content) {
  final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return '新对话';
  return normalized.length > 24 ? normalized.substring(0, 24) : normalized;
}

/// SQLite 3.24 以下的 Android 设备不支持 UPSERT，统一用 update 再 insert。
Future<void> _upsert(
  DatabaseExecutor db,
  String table,
  Map<String, Object?> values,
  String idColumn,
) async {
  final updated = await db.update(
    table,
    values,
    where: '$idColumn = ?',
    whereArgs: [values[idColumn]],
  );
  if (updated == 0) {
    await db.insert(table, values);
  }
}

// ---------------------------------------------------------------------------
// 作品
// ---------------------------------------------------------------------------

Future<List<Project>> listProjects() async {
  final db = await getDatabase();
  final rows = await db.query('projects', orderBy: 'updated_at DESC');
  return rows.map(_mapProject).toList();
}

Future<Project?> getProject(String id) async {
  final db = await getDatabase();
  final rows = await db.query('projects', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapProject(rows.first);
}

Future<Project> createProject(String title, [String description = '']) async {
  final db = await getDatabase();
  final id = createId();
  final now = nowIso();
  final normalizedTitle = requiredText(title, '作品名');
  final normalizedDescription = description.trim();
  final volumeId = createId();
  final chapterId = createId();
  await db.transaction((txn) async {
    await txn.insert('projects', {
      'id': id,
      'title': normalizedTitle,
      'description': normalizedDescription,
      'created_at': now,
      'updated_at': now,
    });
    await txn.insert('volumes', {
      'id': volumeId,
      'project_id': id,
      'title': '正文',
      'order_index': 1,
    });
    await txn.insert('chapters', {
      'id': chapterId,
      'project_id': id,
      'volume_id': volumeId,
      'title': '第一章',
      'content': '',
      'order_index': 1,
      'updated_at': now,
    });
    await _insertFts(txn, chapterId, id, '第一章', '');
  });
  return Project(
    id: id,
    title: normalizedTitle,
    description: normalizedDescription,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> deleteProject(String id) async {
  final db = await getDatabase();
  await db.transaction((txn) async {
    await _deleteFtsByProject(txn, id);
    await txn.delete('projects', where: 'id = ?', whereArgs: [id]);
    await txn.delete(
      'app_settings',
      where: 'key IN (?, ?, ?) OR key = ?',
      whereArgs: [
        'assistant.activeSession.$id',
        'agent.pendingConsistency.$id',
        'plugin.lorn-style-evolution.guide.$id',
        'style.activeProfile.$id',
      ],
    );
  });
}

// ---------------------------------------------------------------------------
// 卷
// ---------------------------------------------------------------------------

Future<List<Volume>> listVolumes(String projectId) async {
  final db = await getDatabase();
  final rows = await db.query(
    'volumes',
    where: 'project_id = ?',
    whereArgs: [projectId],
    orderBy: 'order_index',
  );
  return rows.map(_mapVolume).toList();
}

Future<Volume> createVolume(String projectId, String title) async {
  final db = await getDatabase();
  final id = createId();
  final normalizedTitle = requiredText(title, '卷名');
  final now = nowIso();
  var orderIndex = 1;
  await db.transaction((txn) async {
    final orderRow = await txn.rawQuery(
      'SELECT COALESCE(MAX(order_index), 0) + 1 AS next_order FROM volumes WHERE project_id = ?',
      [projectId],
    );
    orderIndex = (orderRow.first['next_order'] as num?)?.toInt() ?? 1;
    await txn.insert('volumes', {
      'id': id,
      'project_id': projectId,
      'title': normalizedTitle,
      'order_index': orderIndex,
    });
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [projectId]);
  });
  return Volume(id: id, projectId: projectId, title: normalizedTitle, orderIndex: orderIndex);
}

Future<Volume> renameVolume(String id, String title) async {
  final db = await getDatabase();
  final rows = await db.query('volumes', where: 'id = ?', whereArgs: [id], limit: 1);
  if (rows.isEmpty) throw Exception('卷不存在');
  final volume = _mapVolume(rows.first);
  final normalizedTitle = requiredText(title, '卷名');
  final now = nowIso();
  await db.transaction((txn) async {
    await txn.update('volumes', {'title': normalizedTitle}, where: 'id = ?', whereArgs: [id]);
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [volume.projectId]);
  });
  return Volume(
    id: volume.id,
    projectId: volume.projectId,
    title: normalizedTitle,
    orderIndex: volume.orderIndex,
  );
}

Future<void> deleteVolume(String id) async {
  final db = await getDatabase();
  final now = nowIso();
  await db.transaction((txn) async {
    final rows = await txn.query('volumes', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) throw Exception('卷不存在');
    final volume = _mapVolume(rows.first);
    final countRow = await txn.rawQuery(
      'SELECT COUNT(*) AS volume_count FROM volumes WHERE project_id = ?',
      [volume.projectId],
    );
    if (((countRow.first['volume_count'] as num?)?.toInt() ?? 0) <= 1) {
      throw Exception('每部作品至少需要保留一卷');
    }
    final chapterCountRow = await txn.rawQuery(
      'SELECT COUNT(*) AS chapter_count FROM chapters WHERE volume_id = ?',
      [id],
    );
    final chapterCount = (chapterCountRow.first['chapter_count'] as num?)?.toInt() ?? 0;
    await _deleteFtsByVolume(txn, id);
    await txn.rawDelete(
      "DELETE FROM vector_chunks WHERE project_id = ? AND source_type = 'chapter' "
      'AND source_id IN (SELECT id FROM chapters WHERE volume_id = ?)',
      [volume.projectId, id],
    );
    await txn.delete('volumes', where: 'id = ?', whereArgs: [id]);
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [volume.projectId]);
    if (chapterCount > 0) {
      await _upsertSetting(txn, 'agent.pendingConsistency.${volume.projectId}', jsonEncodeMap({
        'change': 'volume_deleted',
        'volumeId': id,
        'volumeTitle': volume.title,
        'chapterCount': chapterCount,
        'updatedAt': now,
      }));
    }
  });
}

// ---------------------------------------------------------------------------
// 章节
// ---------------------------------------------------------------------------

Future<List<Chapter>> listChapters(String projectId) async {
  final db = await getDatabase();
  final rows = await db.rawQuery('''
    SELECT c.* FROM chapters c
    JOIN volumes v ON v.id = c.volume_id
    WHERE c.project_id = ?
    ORDER BY v.order_index, c.order_index
  ''', [projectId]);
  return rows.map(_mapChapter).toList();
}

Future<Chapter?> getChapter(String id) async {
  final db = await getDatabase();
  final rows = await db.query('chapters', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapChapter(rows.first);
}

Future<Chapter> createChapter(
  String projectId,
  String volumeId,
  String title, [
  String content = '',
]) async {
  final db = await getDatabase();
  final id = createId();
  final now = nowIso();
  final normalizedTitle = requiredText(title, '章节标题');
  _validateChapterContent(content);
  final consistencyKey = 'agent.pendingConsistency.$projectId';
  final consistencyValue = jsonEncodeMap({
    'chapterId': id,
    'chapterTitle': normalizedTitle,
    'updatedAt': now,
  });
  var orderIndex = 1;
  await db.transaction((txn) async {
    final volume = await txn.query(
      'volumes',
      columns: ['id'],
      where: 'id = ? AND project_id = ?',
      whereArgs: [volumeId, projectId],
      limit: 1,
    );
    if (volume.isEmpty) throw Exception('卷不属于当前作品');
    final orderRow = await txn.rawQuery(
      'SELECT COALESCE(MAX(order_index), 0) + 1 AS next_order FROM chapters WHERE volume_id = ?',
      [volumeId],
    );
    orderIndex = (orderRow.first['next_order'] as num?)?.toInt() ?? 1;
    await txn.insert('chapters', {
      'id': id,
      'project_id': projectId,
      'volume_id': volumeId,
      'title': normalizedTitle,
      'content': content,
      'order_index': orderIndex,
      'updated_at': now,
    });
    await _insertFts(txn, id, projectId, normalizedTitle, content);
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [projectId]);
    if (content.trim().isNotEmpty) {
      await _upsertSetting(txn, consistencyKey, consistencyValue);
    }
  });
  return Chapter(
    id: id,
    projectId: projectId,
    volumeId: volumeId,
    title: normalizedTitle,
    content: content,
    orderIndex: orderIndex,
    updatedAt: now,
  );
}

Future<void> saveChapter(String id, String title, String content) async {
  final db = await getDatabase();
  final now = nowIso();
  final chapter = await getChapter(id);
  if (chapter == null) throw Exception('章节不存在');
  final normalizedTitle = requiredText(title, '章节标题');
  _validateChapterContent(content);
  final consistencyKey = 'agent.pendingConsistency.${chapter.projectId}';
  await db.transaction((txn) async {
    await txn.update(
      'chapters',
      {'title': normalizedTitle, 'content': content, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [chapter.projectId]);
    await _upsertSetting(txn, consistencyKey, jsonEncodeMap({
      'chapterId': id,
      'chapterTitle': normalizedTitle,
      'updatedAt': now,
    }));
    await txn.rawDelete(
      "DELETE FROM vector_chunks WHERE project_id = ? AND source_type = 'chapter' AND source_id = ?",
      [chapter.projectId, id],
    );
    await _deleteFtsByChapter(txn, id);
    await _insertFts(txn, id, chapter.projectId, normalizedTitle, content);
  });
}

Future<Chapter> renameChapter(String id, String title) async {
  final db = await getDatabase();
  final rows = await db.query('chapters', where: 'id = ?', whereArgs: [id], limit: 1);
  if (rows.isEmpty) throw Exception('章节不存在');
  final chapter = _mapChapter(rows.first);
  final normalizedTitle = requiredText(title, '章节标题');
  final now = nowIso();
  await db.transaction((txn) async {
    await txn.update('chapters', {'title': normalizedTitle, 'updated_at': now}, where: 'id = ?', whereArgs: [id]);
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [chapter.projectId]);
    await txn.rawDelete(
      "DELETE FROM vector_chunks WHERE project_id = ? AND source_type = 'chapter' AND source_id = ?",
      [chapter.projectId, id],
    );
    await _deleteFtsByChapter(txn, id);
    await _insertFts(txn, id, chapter.projectId, normalizedTitle, chapter.content);
    await _upsertSetting(txn, 'agent.pendingConsistency.${chapter.projectId}', jsonEncodeMap({
      'change': 'chapter_renamed',
      'chapterId': id,
      'chapterTitle': normalizedTitle,
      'updatedAt': now,
    }));
  });
  return Chapter(
    id: chapter.id,
    projectId: chapter.projectId,
    volumeId: chapter.volumeId,
    title: normalizedTitle,
    content: chapter.content,
    orderIndex: chapter.orderIndex,
    updatedAt: now,
  );
}

Future<void> deleteChapter(String id) async {
  final db = await getDatabase();
  final now = nowIso();
  await db.transaction((txn) async {
    final rows = await txn.query('chapters', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) throw Exception('章节不存在');
    final chapter = _mapChapter(rows.first);
    await _deleteFtsByChapter(txn, id);
    await txn.rawDelete(
      "DELETE FROM vector_chunks WHERE project_id = ? AND source_type = 'chapter' AND source_id = ?",
      [chapter.projectId, id],
    );
    await txn.delete('chapters', where: 'id = ?', whereArgs: [id]);
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [chapter.projectId]);
    await _upsertSetting(txn, 'agent.pendingConsistency.${chapter.projectId}', jsonEncodeMap({
      'change': 'chapter_deleted',
      'chapterId': id,
      'chapterTitle': chapter.title,
      'updatedAt': now,
    }));
  });
}

Future<List<Chapter>> searchChapters(String projectId, String query) async {
  final db = await getDatabase();
  final terms = query
      .trim()
      .replaceAll(RegExp(r'[^\p{L}\p{N}_]+', unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList();
  if (terms.isEmpty) return [];
  final matchQuery = terms
      .map((term) => '"${term.replaceAll('"', '""')}"*')
      .join(' AND ');
  try {
    final rows = await db.rawQuery('''
      SELECT c.* FROM chapter_fts f JOIN chapters c ON c.id = f.chapter_id
      WHERE f.project_id = ? AND chapter_fts MATCH ? ORDER BY rank LIMIT 20
    ''', [projectId, matchQuery]);
    return rows.map(_mapChapter).toList();
  } catch (_) {
    final likeQuery = '%${query.trim()}%';
    final rows = await db.rawQuery('''
      SELECT * FROM chapters WHERE project_id = ? AND (title LIKE ? OR content LIKE ?)
      ORDER BY updated_at DESC LIMIT 20
    ''', [projectId, likeQuery, likeQuery]);
    return rows.map(_mapChapter).toList();
  }
}

// ---------------------------------------------------------------------------
// 供应商与模型
// ---------------------------------------------------------------------------

Future<List<Provider>> listProviders() async {
  final db = await getDatabase();
  final rows = await db.query('providers', orderBy: 'created_at');
  return rows.map(_mapProvider).toList();
}

Future<Provider> saveProvider({
  String? id,
  required String name,
  required ProviderType type,
  required String baseUrl,
  required String apiKey,
}) async {
  final db = await getDatabase();
  final providerId = id ?? createId();
  final normalizedName = requiredText(name, '供应商名称');
  final normalizedUrl = normalizeBaseUrl(baseUrl);
  final normalizedKey = requiredText(apiKey, 'API Key');
  final apiKeyRef = 'openfic.provider.$providerId';
  final now = nowIso();
  final existing = await db.query('providers', where: 'id = ?', whereArgs: [providerId], limit: 1);
  final previousApiKey = existing.isEmpty
      ? null
      : await SecureStore.read(existing.first['api_key_ref'] as String);
  await SecureStore.write(apiKeyRef, normalizedKey);
  try {
    await db.transaction((txn) async {
      await _upsert(txn, 'providers', {
        'id': providerId,
        'name': normalizedName,
        'type': type.wire,
        'base_url': normalizedUrl,
        'api_key_ref': apiKeyRef,
        'created_at': existing.isEmpty ? now : existing.first['created_at'],
      }, 'id');
    });
  } catch (error) {
    if (previousApiKey == null) {
      await SecureStore.delete(apiKeyRef);
    } else {
      await SecureStore.write(apiKeyRef, previousApiKey);
    }
    rethrow;
  }
  return Provider(
    id: providerId,
    name: normalizedName,
    type: type,
    baseUrl: normalizedUrl,
    apiKeyRef: apiKeyRef,
    createdAt: existing.isEmpty ? now : existing.first['created_at'] as String,
  );
}

Future<String> getProviderApiKey(Provider provider) async {
  return (await SecureStore.read(provider.apiKeyRef)) ?? '';
}

Future<void> deleteProvider(Provider provider) async {
  final db = await getDatabase();
  await db.transaction((txn) async {
    final active = await txn.query('app_settings',
        columns: ['value'], where: 'key = ?', whereArgs: ['activeModelId'], limit: 1);
    if (active.isNotEmpty) {
      final activeModel = await txn.query('models',
          columns: ['provider_id'],
          where: 'id = ?',
          whereArgs: [active.first['value']],
          limit: 1);
      if (activeModel.isNotEmpty && activeModel.first['provider_id'] == provider.id) {
        await txn.delete('app_settings', where: 'key = ?', whereArgs: ['activeModelId']);
      }
    }
    await txn.rawUpdate(
      'UPDATE chat_sessions SET model_id = NULL WHERE model_id IN (SELECT id FROM models WHERE provider_id = ?)',
      [provider.id],
    );
    await txn.delete('models', where: 'provider_id = ?', whereArgs: [provider.id]);
    await txn.delete('providers', where: 'id = ?', whereArgs: [provider.id]);
  });
  await SecureStore.delete(provider.apiKeyRef);
}

Future<List<LlmModel>> listModels([String? providerId]) async {
  final db = await getDatabase();
  final rows = providerId == null
      ? await db.rawQuery(
          'SELECT models.* FROM models INNER JOIN providers ON providers.id = models.provider_id ORDER BY models.name')
      : await db.rawQuery(
          'SELECT models.* FROM models INNER JOIN providers ON providers.id = models.provider_id '
          'WHERE models.provider_id = ? ORDER BY models.name',
          [providerId]);
  return rows.map(_mapModel).toList();
}

Future<LlmModel> saveModel({
  String? id,
  required String providerId,
  required String name,
  required String modelId,
  required double temperature,
  required int maxTokens,
}) async {
  final db = await getDatabase();
  final modelIdValue = id ?? createId();
  final normalizedName = requiredText(name, '模型名称');
  final normalizedModelId = requiredText(modelId, '模型 ID');
  if (!temperature.isFinite || temperature < 0 || temperature > 2) {
    throw Exception('温度必须在 0 到 2 之间');
  }
  if (maxTokens < 1 || maxTokens > maxConfiguredOutputTokens) {
    throw Exception(
      '最大输出 Token 数必须在 1 到 $maxConfiguredOutputTokens 之间；1M 通常是上下文窗口，不是单次输出上限',
    );
  }
  final provider = await db.query('providers', columns: ['id'],
      where: 'id = ?', whereArgs: [providerId], limit: 1);
  if (provider.isEmpty) throw Exception('供应商不存在');
  await db.transaction((txn) async {
    await _upsert(txn, 'models', {
      'id': modelIdValue,
      'provider_id': providerId,
      'name': normalizedName,
      'model_id': normalizedModelId,
      'temperature': temperature,
      'max_tokens': maxTokens,
    }, 'id');
  });
  return LlmModel(
    id: modelIdValue,
    providerId: providerId,
    name: normalizedName,
    modelId: normalizedModelId,
    temperature: temperature,
    maxTokens: maxTokens,
  );
}

Future<void> deleteModel(String id) async {
  final db = await getDatabase();
  await db.transaction((txn) async {
    final active = await txn.query('app_settings',
        columns: ['value'], where: 'key = ?', whereArgs: ['activeModelId'], limit: 1);
    if (active.isNotEmpty && active.first['value'] == id) {
      await txn.delete('app_settings', where: 'key = ?', whereArgs: ['activeModelId']);
    }
    await txn.rawUpdate('UPDATE chat_sessions SET model_id = NULL WHERE model_id = ?', [id]);
    await txn.delete('models', where: 'id = ?', whereArgs: [id]);
  });
}

// ---------------------------------------------------------------------------
// 会话与消息
// ---------------------------------------------------------------------------

Future<List<ChatSession>> listChatSessions(String projectId) async {
  final db = await getDatabase();
  final rows = await db.query(
    'chat_sessions',
    where: 'project_id = ?',
    whereArgs: [projectId],
    orderBy: 'updated_at DESC, created_at DESC',
  );
  return rows.map(_mapSession).toList();
}

Future<ChatSession?> getChatSession(String id) async {
  final db = await getDatabase();
  final rows = await db.query('chat_sessions', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapSession(rows.first);
}

Future<ChatSession> createChatSession(String projectId, [String? modelId]) async {
  final db = await getDatabase();
  final project = await db.query('projects', columns: ['id'],
      where: 'id = ?', whereArgs: [projectId], limit: 1);
  if (project.isEmpty) throw Exception('作品不存在');
  final normalizedModelId = (modelId == null || modelId.trim().isEmpty) ? null : modelId.trim();
  if (normalizedModelId != null) {
    final model = await db.query('models', columns: ['id'],
        where: 'id = ?', whereArgs: [normalizedModelId], limit: 1);
    if (model.isEmpty) throw Exception('模型不存在');
  }
  final now = nowIso();
  final session = ChatSession(
    id: createId(),
    projectId: projectId,
    title: '新对话',
    modelId: normalizedModelId,
    createdAt: now,
    updatedAt: now,
  );
  await db.insert('chat_sessions', {
    'id': session.id,
    'project_id': session.projectId,
    'title': session.title,
    'model_id': session.modelId,
    'created_at': session.createdAt,
    'updated_at': session.updatedAt,
  });
  return session;
}

Future<ChatSession> updateChatSession({
  required String id,
  String? title,
  Object? modelId = _unset,
}) async {
  final db = await getDatabase();
  final rows = await db.query('chat_sessions', where: 'id = ?', whereArgs: [id], limit: 1);
  if (rows.isEmpty) throw Exception('对话不存在');
  final existing = _mapSession(rows.first);
  var nextTitle = existing.title;
  if (title != null) {
    final normalized = requiredText(title, '对话标题');
    nextTitle = normalized.length > 80 ? normalized.substring(0, 80) : normalized;
  }
  final String? nextModelId;
  if (identical(modelId, _unset)) {
    nextModelId = existing.modelId;
  } else {
    final raw = (modelId as String?)?.trim();
    nextModelId = (raw == null || raw.isEmpty) ? null : raw;
  }
  if (nextModelId != null) {
    final model = await db.query('models', columns: ['id'],
        where: 'id = ?', whereArgs: [nextModelId], limit: 1);
    if (model.isEmpty) throw Exception('模型不存在');
  }
  final updatedAt = nowIso();
  await db.update(
    'chat_sessions',
    {'title': nextTitle, 'model_id': nextModelId, 'updated_at': updatedAt},
    where: 'id = ?',
    whereArgs: [id],
  );
  return ChatSession(
    id: existing.id,
    projectId: existing.projectId,
    title: nextTitle,
    modelId: nextModelId,
    createdAt: existing.createdAt,
    updatedAt: updatedAt,
  );
}

const Object _unset = Object();

Future<void> deleteChatSession(String id) async {
  final db = await getDatabase();
  await db.delete('chat_sessions', where: 'id = ?', whereArgs: [id]);
}

Future<List<ChatMessage>> listMessages(String sessionId) async {
  final db = await getDatabase();
  final rows = await db.query(
    'chat_messages',
    where: 'session_id = ?',
    whereArgs: [sessionId],
    orderBy: 'created_at, rowid',
  );
  return rows.map(_mapMessage).toList();
}

const List<String> _messageColumnsWithRowId = [
  'rowid',
  'id',
  'project_id',
  'session_id',
  'role',
  'content',
  'metadata_json',
  'created_at',
];

/// 分页读取消息：默认取最新一页；传入 [beforeRowId] 取更早的一页。
/// 返回按时间升序的消息、本页最早一行的 rowid 以及是否还有更早消息。
Future<({List<ChatMessage> messages, int? oldestRowId, bool hasMore})> listRecentMessagePage(
  String sessionId, {
  int limit = 30,
  int? beforeRowId,
}) async {
  final db = await getDatabase();
  final rows = beforeRowId == null
      ? await db.query('chat_messages',
          columns: _messageColumnsWithRowId,
          where: 'session_id = ?',
          whereArgs: [sessionId],
          orderBy: 'rowid DESC',
          limit: limit)
      : await db.query('chat_messages',
          columns: _messageColumnsWithRowId,
          where: 'session_id = ? AND rowid < ?',
          whereArgs: [sessionId, beforeRowId],
          orderBy: 'rowid DESC',
          limit: limit);
  if (rows.isEmpty) {
    return (messages: <ChatMessage>[], oldestRowId: beforeRowId, hasMore: false);
  }
  final oldestRowId = rows.last['rowid'] as int;
  final messages = rows.map(_mapMessage).toList().reversed.toList();
  return (messages: messages, oldestRowId: oldestRowId, hasMore: rows.length == limit);
}

Future<void> deleteMessagesFrom(String sessionId, String messageId) async {
  final db = await getDatabase();
  await db.transaction((txn) async {
    final target = await txn.query('chat_messages',
        columns: ['rowid'],
        where: 'session_id = ? AND id = ?',
        whereArgs: [sessionId, messageId],
        limit: 1);
    if (target.isEmpty) throw Exception('要编辑的消息不存在');
    final rowid = target.first['rowid'] as int;
    await txn.delete('chat_messages', where: 'session_id = ? AND rowid >= ?', whereArgs: [sessionId, rowid]);
    await txn.update('chat_sessions', {'updated_at': nowIso()}, where: 'id = ?', whereArgs: [sessionId]);
  });
}

Future<({ChatMessage message, ChatSession session})> replaceUserMessageBranch(
  String sessionId,
  String messageId,
  String content,
) async {
  if (content.trim().isEmpty) throw Exception('消息内容不能为空');
  final db = await getDatabase();
  late ChatMessage message;
  late ChatSession session;
  await db.transaction((txn) async {
    final sessionRows = await txn.query('chat_sessions', where: 'id = ?', whereArgs: [sessionId], limit: 1);
    if (sessionRows.isEmpty) throw Exception('对话不存在');
    final existingSession = _mapSession(sessionRows.first);
    final target = await txn.query('chat_messages',
        columns: ['rowid', 'role'],
        where: 'session_id = ? AND id = ?',
        whereArgs: [sessionId, messageId],
        limit: 1);
    if (target.isEmpty || target.first['role'] != 'user') {
      throw Exception('要编辑的用户消息不存在');
    }
    final rowid = target.first['rowid'] as int;
    final earlierUser = await txn.rawQuery(
      "SELECT 1 AS found FROM chat_messages WHERE session_id = ? AND role = 'user' AND rowid < ? LIMIT 1",
      [sessionId, rowid],
    );
    final createdAt = nowIso();
    message = ChatMessage(
      id: createId(),
      projectId: existingSession.projectId,
      sessionId: sessionId,
      role: 'user',
      content: content,
      createdAt: createdAt,
    );
    final title = earlierUser.isEmpty ? _generatedMessageTitle(content) : existingSession.title;
    await txn.delete('chat_messages', where: 'session_id = ? AND rowid >= ?', whereArgs: [sessionId, rowid]);
    await txn.insert('chat_messages', {
      'id': message.id,
      'project_id': message.projectId,
      'session_id': message.sessionId,
      'role': 'user',
      'content': message.content,
      'metadata_json': null,
      'created_at': message.createdAt,
    });
    await txn.update('chat_sessions', {'title': title, 'updated_at': createdAt},
        where: 'id = ?', whereArgs: [sessionId]);
    session = ChatSession(
      id: existingSession.id,
      projectId: existingSession.projectId,
      title: title,
      modelId: existingSession.modelId,
      createdAt: existingSession.createdAt,
      updatedAt: createdAt,
    );
  });
  return (message: message, session: session);
}

Future<ChatMessage> addMessage(
  String sessionId,
  String role,
  String content, [
  ChatMessageMetadata? metadata,
]) async {
  if (content.trim().isEmpty) throw Exception('消息内容不能为空');
  final db = await getDatabase();
  final sessionRows = await db.query('chat_sessions', where: 'id = ?', whereArgs: [sessionId], limit: 1);
  if (sessionRows.isEmpty) throw Exception('对话不存在');
  final session = _mapSession(sessionRows.first);
  final createdAt = nowIso();
  final message = ChatMessage(
    id: createId(),
    projectId: session.projectId,
    sessionId: sessionId,
    role: role,
    content: content,
    metadata: metadata,
    createdAt: createdAt,
  );
  final generatedTitle = _generatedMessageTitle(content);
  final metadataJson = metadata == null ? null : jsonEncodeMap(metadata.toJson());
  await db.transaction((txn) async {
    await txn.insert('chat_messages', {
      'id': message.id,
      'project_id': message.projectId,
      'session_id': message.sessionId,
      'role': message.role,
      'content': message.content,
      'metadata_json': metadataJson,
      'created_at': message.createdAt,
    });
    await txn.rawUpdate(
      "UPDATE chat_sessions SET title = CASE WHEN title = '新对话' AND ? = 'user' THEN ? ELSE title END, "
      'updated_at = ? WHERE id = ?',
      [role, generatedTitle, createdAt, sessionId],
    );
  });
  return message;
}

Future<void> saveMessageMetadata(String messageId, ChatMessageMetadata metadata) async {
  final db = await getDatabase();
  await db.update(
    'chat_messages',
    {'metadata_json': jsonEncodeMap(metadata.toJson())},
    where: 'id = ?',
    whereArgs: [messageId],
  );
}

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------

Future<String?> getSetting(String key) async {
  final db = await getDatabase();
  final rows = await db.query('app_settings',
      columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
  return rows.isEmpty ? null : rows.first['value'] as String?;
}

Future<void> setSetting(String key, String value) async {
  final db = await getDatabase();
  await _upsertSetting(db, key, value);
}

Future<void> setSettings(List<(String, String)> entries) async {
  if (entries.isEmpty) return;
  final db = await getDatabase();
  await db.transaction((txn) async {
    for (final entry in entries) {
      await _upsertSetting(txn, entry.$1, entry.$2);
    }
  });
}

Future<void> deleteSetting(String key) async {
  final db = await getDatabase();
  await db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
}

Future<void> _upsertSetting(DatabaseExecutor db, String key, String value) async {
  final updated = await db.update(
    'app_settings',
    {'value': value},
    where: 'key = ?',
    whereArgs: [key],
  );
  if (updated == 0) {
    await db.insert('app_settings', {'key': key, 'value': value});
  }
}

// ---------------------------------------------------------------------------
// 角色
// ---------------------------------------------------------------------------

Future<List<Character>> listCharacters(String projectId, [String query = '']) async {
  final db = await getDatabase();
  final normalized = query.trim();
  final rows = normalized.isEmpty
      ? await db.query('characters',
          where: 'project_id = ?',
          whereArgs: [projectId],
          orderBy: 'is_favorited DESC, updated_at DESC')
      : await db.query('characters',
          where: 'project_id = ? AND (name LIKE ? OR description LIKE ?)',
          whereArgs: [projectId, '%$normalized%', '%$normalized%'],
          orderBy: 'is_favorited DESC, updated_at DESC');
  return rows.map(_mapCharacter).toList();
}

Future<Character?> getCharacter(String id) async {
  final db = await getDatabase();
  final rows = await db.query('characters', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapCharacter(rows.first);
}

Future<Character> saveCharacter({
  String? id,
  required String projectId,
  required String name,
  String? description,
  String? imagePath,
  bool? isFavorited,
}) async {
  final db = await getDatabase();
  final characterId = id ?? createId();
  final normalizedName = requiredText(name, '角色名称');
  final normalizedDescription = (description ?? '').trim();
  _validateChapterContent(normalizedDescription);
  final now = nowIso();
  final existing = await db.query('characters', where: 'id = ?', whereArgs: [characterId], limit: 1);
  await _upsert(db, 'characters', {
    'id': characterId,
    'project_id': projectId,
    'name': normalizedName,
    'description': normalizedDescription,
    'image_path': imagePath,
    'is_favorited': (isFavorited ?? false) ? 1 : 0,
    'created_at': existing.isEmpty ? now : existing.first['created_at'],
    'updated_at': now,
  }, 'id');
  return Character(
    id: characterId,
    projectId: projectId,
    name: normalizedName,
    description: normalizedDescription,
    imagePath: imagePath,
    isFavorited: isFavorited ?? false,
    createdAt: existing.isEmpty ? now : existing.first['created_at'] as String,
    updatedAt: now,
  );
}

Future<void> deleteCharacter(String id) async {
  final db = await getDatabase();
  final now = nowIso();
  await db.transaction((txn) async {
    final rows = await txn.query('characters', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) throw Exception('角色不存在');
    final character = _mapCharacter(rows.first);
    await txn.rawDelete(
      "DELETE FROM vector_chunks WHERE project_id = ? AND source_type = 'character' AND source_id = ?",
      [character.projectId, id],
    );
    await txn.delete('characters', where: 'id = ?', whereArgs: [id]);
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [character.projectId]);
  });
}

// ---------------------------------------------------------------------------
// 世界书
// ---------------------------------------------------------------------------

Future<WorldInfo> getOrCreateWorldInfo(String projectId) async {
  final db = await getDatabase();
  final existing = await db.query('world_info',
      where: 'project_id = ?', whereArgs: [projectId], limit: 1);
  if (existing.isNotEmpty) return _mapWorldInfo(existing.first);
  final id = createId();
  final now = nowIso();
  await db.insert('world_info', {
    'id': id,
    'project_id': projectId,
    'name': '世界书',
    'description': '',
    'created_at': now,
    'updated_at': now,
  });
  return WorldInfo(
    id: id,
    projectId: projectId,
    name: '世界书',
    description: '',
    createdAt: now,
    updatedAt: now,
  );
}

Future<WorldInfo> saveWorldInfo({
  required String id,
  required String projectId,
  required String name,
  String? description,
}) async {
  final db = await getDatabase();
  final existing = await db.query('world_info',
      where: 'id = ? AND project_id = ?', whereArgs: [id, projectId], limit: 1);
  if (existing.isEmpty) throw Exception('世界书不存在');
  final normalizedName = requiredText(name, '世界书名称');
  final normalizedDescription = (description ?? '').trim();
  final now = nowIso();
  await db.update(
    'world_info',
    {'name': normalizedName, 'description': normalizedDescription, 'updated_at': now},
    where: 'id = ? AND project_id = ?',
    whereArgs: [id, projectId],
  );
  return WorldInfo(
    id: id,
    projectId: projectId,
    name: normalizedName,
    description: normalizedDescription,
    createdAt: existing.first['created_at'] as String,
    updatedAt: now,
  );
}

Future<List<WorldInfoEntry>> listWorldInfoEntries(String worldInfoId) async {
  final db = await getDatabase();
  final rows = await db.query(
    'world_info_entries',
    where: 'world_info_id = ?',
    whereArgs: [worldInfoId],
    orderBy: 'entry_order, uid',
  );
  return rows.map(_mapWorldEntry).toList();
}

Future<WorldInfoEntry?> getWorldInfoEntry(String id) async {
  final db = await getDatabase();
  final rows = await db.query('world_info_entries', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapWorldEntry(rows.first);
}

Future<WorldInfoEntry> saveWorldInfoEntry({
  String? id,
  required String worldInfoId,
  required String name,
  String? content,
  bool? isEnabled,
}) async {
  final db = await getDatabase();
  final entryId = id ?? createId();
  final normalizedName = requiredText(name, '世界书条目名称');
  final normalizedContent = (content ?? '').trim();
  _validateChapterContent(normalizedContent);
  final now = nowIso();
  final existing = await db.query('world_info_entries',
      where: 'id = ?', whereArgs: [entryId], limit: 1);
  var uid = existing.isEmpty ? null : existing.first['uid'] as int?;
  var order = existing.isEmpty ? null : existing.first['entry_order'] as int?;
  if (uid == null || order == null) {
    final next = await db.rawQuery(
      'SELECT COALESCE(MAX(uid), 0) + 1 AS next_uid FROM world_info_entries WHERE world_info_id = ?',
      [worldInfoId],
    );
    uid = (next.first['next_uid'] as num?)?.toInt() ?? 1;
    order = uid;
  }
  await _upsert(db, 'world_info_entries', {
    'id': entryId,
    'world_info_id': worldInfoId,
    'uid': uid,
    'name': normalizedName,
    'entry_order': order,
    'content': normalizedContent,
    'token_count': normalizedContent.length,
    'is_enabled': (isEnabled ?? true) ? 1 : 0,
    'created_at': existing.isEmpty ? now : existing.first['created_at'],
    'updated_at': now,
  }, 'id');
  return WorldInfoEntry(
    id: entryId,
    worldInfoId: worldInfoId,
    uid: uid,
    name: normalizedName,
    order: order,
    content: normalizedContent,
    tokenCount: normalizedContent.length,
    isEnabled: isEnabled ?? true,
    createdAt: existing.isEmpty ? now : existing.first['created_at'] as String,
    updatedAt: now,
  );
}

Future<void> deleteWorldInfoEntry(String id) async {
  final db = await getDatabase();
  final now = nowIso();
  await db.transaction((txn) async {
    final rows = await txn.rawQuery('''
      SELECT entry.*, world.project_id FROM world_info_entries entry
      JOIN world_info world ON world.id = entry.world_info_id
      WHERE entry.id = ?
    ''', [id]);
    if (rows.isEmpty) throw Exception('世界书条目不存在');
    final entry = rows.first;
    final projectId = entry['project_id'] as String;
    await txn.rawDelete(
      "DELETE FROM vector_chunks WHERE project_id = ? AND source_type = 'world-entry' AND source_id = ?",
      [projectId, id],
    );
    await txn.delete('world_info_entries', where: 'id = ?', whereArgs: [id]);
    await txn.update('world_info', {'updated_at': now},
        where: 'id = ?', whereArgs: [entry['world_info_id']]);
    await txn.update('projects', {'updated_at': now}, where: 'id = ?', whereArgs: [projectId]);
  });
}

// ---------------------------------------------------------------------------
// FTS 辅助（表可能不存在）
// ---------------------------------------------------------------------------

Future<void> _insertFts(DatabaseExecutor db, String chapterId, String projectId, String title, String content) async {
  try {
    await db.rawInsert(
      'INSERT INTO chapter_fts(chapter_id, project_id, title, content) VALUES (?, ?, ?, ?)',
      [chapterId, projectId, title, content],
    );
  } catch (_) {}
}

Future<void> _deleteFtsByChapter(DatabaseExecutor db, String chapterId) async {
  try {
    await db.rawDelete('DELETE FROM chapter_fts WHERE chapter_id = ?', [chapterId]);
  } catch (_) {}
}

Future<void> _deleteFtsByProject(DatabaseExecutor db, String projectId) async {
  try {
    await db.rawDelete('DELETE FROM chapter_fts WHERE project_id = ?', [projectId]);
  } catch (_) {}
}

Future<void> _deleteFtsByVolume(DatabaseExecutor db, String volumeId) async {
  try {
    await db.rawDelete(
      'DELETE FROM chapter_fts WHERE chapter_id IN (SELECT id FROM chapters WHERE volume_id = ?)',
      [volumeId],
    );
  } catch (_) {}
}

Map<String, dynamic>? jsonDecodeMap(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return decoded.map((key, item) => MapEntry('$key', item));
    }
    return null;
  } catch (_) {
    return null;
  }
}

String jsonEncodeMap(Map<String, dynamic> value) => jsonEncode(value);