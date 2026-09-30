import '../core/utils.dart';
import '../models.dart';
import 'database.dart';

const int maxNoteTitleCharacters = 200;
const int maxNoteContentCharacters = 100000;

Note _mapNote(Map<String, Object?> row) => Note(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      volumeId: row['volume_id'] as String?,
      chapterId: row['chapter_id'] as String?,
      title: row['title'] as String,
      content: row['content'] as String? ?? '',
      orderIndex: row['order_index'] as int,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

String _requiredText(String value, String label, int maximum) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw Exception('$label不能为空');
  if (normalized.length > maximum) throw Exception('$label超过 $maximum 字符限制');
  return normalized;
}

/// 归一化归属目标。章优先于卷；给了章就从章反查所属卷，避免归属不一致。
Future<({String? volumeId, String? chapterId})> _resolveTarget(
  String projectId, {
  String? volumeId,
  String? chapterId,
}) async {
  final database = await getDatabase();
  final normalizedChapter = chapterId?.trim();
  if (normalizedChapter != null && normalizedChapter.isNotEmpty) {
    final rows = await database.query('chapters',
        columns: ['volume_id', 'project_id'],
        where: 'id = ?',
        whereArgs: [normalizedChapter],
        limit: 1);
    if (rows.isEmpty) throw Exception('章节不存在');
    if (rows.first['project_id'] != projectId) throw Exception('章节不属于当前作品');
    return (volumeId: rows.first['volume_id'] as String, chapterId: normalizedChapter);
  }
  final normalizedVolume = volumeId?.trim();
  if (normalizedVolume != null && normalizedVolume.isNotEmpty) {
    final rows = await database.query('volumes',
        columns: ['project_id'], where: 'id = ?', whereArgs: [normalizedVolume], limit: 1);
    if (rows.isEmpty) throw Exception('卷不存在');
    if (rows.first['project_id'] != projectId) throw Exception('卷不属于当前作品');
    return (volumeId: normalizedVolume, chapterId: null);
  }
  return (volumeId: null, chapterId: null);
}

Future<List<Note>> listNotes(String projectId) async {
  final database = await getDatabase();
  final rows = await database.rawQuery('''
    SELECT * FROM notes WHERE project_id = ?
    ORDER BY CASE WHEN chapter_id IS NOT NULL THEN 2 WHEN volume_id IS NOT NULL THEN 1 ELSE 0 END,
             order_index, created_at
  ''', [projectId]);
  return rows.map(_mapNote).toList();
}

/// 取写作当前位置相关的三层笔记：整书 + 所在卷 + 该章。
Future<List<Note>> listNotesInScope({
  required String projectId,
  String? volumeId,
  String? chapterId,
}) async {
  final database = await getDatabase();
  final rows = await database.rawQuery('''
    SELECT * FROM notes
    WHERE project_id = ?
      AND (
        (volume_id IS NULL AND chapter_id IS NULL)
        OR (chapter_id IS NULL AND volume_id IS NOT NULL AND volume_id = ?)
        OR (chapter_id IS NOT NULL AND chapter_id = ?)
      )
    ORDER BY CASE WHEN chapter_id IS NOT NULL THEN 2 WHEN volume_id IS NOT NULL THEN 1 ELSE 0 END,
             order_index, created_at
  ''', [projectId, volumeId ?? '', chapterId ?? '']);
  return rows.map(_mapNote).toList();
}

Future<Note?> getNote(String id) async {
  final database = await getDatabase();
  final rows = await database.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : _mapNote(rows.first);
}

Future<Note> createNote({
  required String projectId,
  required String title,
  String? content,
  String? volumeId,
  String? chapterId,
}) async {
  final database = await getDatabase();
  final project = await database.query('projects',
      columns: ['id'], where: 'id = ?', whereArgs: [projectId], limit: 1);
  if (project.isEmpty) throw Exception('作品不存在');
  final normalizedTitle = _requiredText(title, '笔记标题', maxNoteTitleCharacters);
  final normalizedContent = (content ?? '').trim();
  if (normalizedContent.length > maxNoteContentCharacters) {
    throw Exception('笔记内容超过 $maxNoteContentCharacters 字符限制');
  }
  final target = await _resolveTarget(projectId, volumeId: volumeId, chapterId: chapterId);
  final id = createId();
  final now = nowIso();
  final next = await database.rawQuery('''
    SELECT COALESCE(MAX(order_index), -1) + 1 AS value FROM notes
    WHERE project_id = ? AND volume_id IS ? AND chapter_id IS ?
  ''', [projectId, target.volumeId, target.chapterId]);
  final orderIndex = (next.first['value'] as num?)?.toInt() ?? 0;
  await database.insert('notes', {
    'id': id,
    'project_id': projectId,
    'volume_id': target.volumeId,
    'chapter_id': target.chapterId,
    'title': normalizedTitle,
    'content': normalizedContent,
    'order_index': orderIndex,
    'created_at': now,
    'updated_at': now,
  });
  return Note(
    id: id,
    projectId: projectId,
    volumeId: target.volumeId,
    chapterId: target.chapterId,
    title: normalizedTitle,
    content: normalizedContent,
    orderIndex: orderIndex,
    createdAt: now,
    updatedAt: now,
  );
}

Future<Note> updateNote({required String id, String? title, String? content}) async {
  final database = await getDatabase();
  final rows = await database.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
  if (rows.isEmpty) throw Exception('笔记不存在');
  final existing = _mapNote(rows.first);
  final nextTitle = title == null
      ? existing.title
      : _requiredText(title, '笔记标题', maxNoteTitleCharacters);
  final nextContent = content == null ? existing.content : content.trim();
  if (nextContent.length > maxNoteContentCharacters) {
    throw Exception('笔记内容超过 $maxNoteContentCharacters 字符限制');
  }
  final updatedAt = nowIso();
  await database.update(
    'notes',
    {'title': nextTitle, 'content': nextContent, 'updated_at': updatedAt},
    where: 'id = ?',
    whereArgs: [id],
  );
  return Note(
    id: existing.id,
    projectId: existing.projectId,
    volumeId: existing.volumeId,
    chapterId: existing.chapterId,
    title: nextTitle,
    content: nextContent,
    orderIndex: existing.orderIndex,
    createdAt: existing.createdAt,
    updatedAt: updatedAt,
  );
}

Future<Note> moveNote(String id, {String? volumeId, String? chapterId}) async {
  final database = await getDatabase();
  final rows = await database.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
  if (rows.isEmpty) throw Exception('笔记不存在');
  final existing = _mapNote(rows.first);
  final resolved = await _resolveTarget(existing.projectId, volumeId: volumeId, chapterId: chapterId);
  final updatedAt = nowIso();
  final next = await database.rawQuery('''
    SELECT COALESCE(MAX(order_index), -1) + 1 AS value FROM notes
    WHERE project_id = ? AND volume_id IS ? AND chapter_id IS ? AND id <> ?
  ''', [existing.projectId, resolved.volumeId, resolved.chapterId, id]);
  final orderIndex = (next.first['value'] as num?)?.toInt() ?? 0;
  await database.update(
    'notes',
    {
      'volume_id': resolved.volumeId,
      'chapter_id': resolved.chapterId,
      'order_index': orderIndex,
      'updated_at': updatedAt,
    },
    where: 'id = ?',
    whereArgs: [id],
  );
  return Note(
    id: existing.id,
    projectId: existing.projectId,
    volumeId: resolved.volumeId,
    chapterId: resolved.chapterId,
    title: existing.title,
    content: existing.content,
    orderIndex: orderIndex,
    createdAt: existing.createdAt,
    updatedAt: updatedAt,
  );
}

Future<void> deleteNote(String id) async {
  final database = await getDatabase();
  await database.delete('notes', where: 'id = ?', whereArgs: [id]);
}

/// 删除章节或卷前用来提示用户有多少条笔记会受影响。
Future<int> countNotesUnder({String? volumeId, String? chapterId}) async {
  final database = await getDatabase();
  if (chapterId != null) {
    final rows = await database
        .rawQuery('SELECT COUNT(*) AS value FROM notes WHERE chapter_id = ?', [chapterId]);
    return (rows.first['value'] as num?)?.toInt() ?? 0;
  }
  if (volumeId != null) {
    final rows = await database.rawQuery('''
      SELECT COUNT(*) AS value FROM notes
      WHERE volume_id = ? OR chapter_id IN (SELECT id FROM chapters WHERE volume_id = ?)
    ''', [volumeId, volumeId]);
    return (rows.first['value'] as num?)?.toInt() ?? 0;
  }
  return 0;
}

/// 用户在删除确认框里选择"一并删除"时调用；不调用则外键 SET NULL 会让笔记上浮。
Future<void> deleteNotesUnder({String? volumeId, String? chapterId}) async {
  final database = await getDatabase();
  if (chapterId != null) {
    await database.delete('notes', where: 'chapter_id = ?', whereArgs: [chapterId]);
    return;
  }
  if (volumeId != null) {
    await database.rawDelete('''
      DELETE FROM notes
      WHERE volume_id = ? OR chapter_id IN (SELECT id FROM chapters WHERE volume_id = ?)
    ''', [volumeId, volumeId]);
  }
}