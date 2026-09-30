import '../core/utils.dart';
import '../models.dart';
import 'database.dart';

ChapterDraftSnapshot _map(Map<String, Object?> row) => ChapterDraftSnapshot(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      chapterId: row['chapter_id'] as String,
      styleProfileId: row['style_profile_id'] as String?,
      aiDraft: row['ai_draft'] as String,
      authorRevision: row['author_revision'] as String?,
      status: ChapterDraftStatus.fromWire(row['status'] as String),
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );

Future<ChapterDraftSnapshot> createChapterDraftSnapshot({
  required String projectId,
  required String chapterId,
  required String? styleProfileId,
  required String aiDraft,
}) async {
  if (aiDraft.trim().isEmpty) throw Exception('AI 原稿不能为空');
  final database = await getDatabase();
  final chapter = await database.query('chapters',
      columns: ['id'],
      where: 'id = ? AND project_id = ?',
      whereArgs: [chapterId, projectId],
      limit: 1);
  if (chapter.isEmpty) throw Exception('章节不存在');
  final now = nowIso();
  final id = createId();
  await database.insert('chapter_drafts', {
    'id': id,
    'project_id': projectId,
    'chapter_id': chapterId,
    'style_profile_id': styleProfileId,
    'ai_draft': aiDraft,
    'author_revision': null,
    'status': 'generated',
    'created_at': now,
    'updated_at': now,
  });
  return ChapterDraftSnapshot(
    id: id,
    projectId: projectId,
    chapterId: chapterId,
    styleProfileId: styleProfileId,
    aiDraft: aiDraft,
    status: ChapterDraftStatus.generated,
    createdAt: now,
    updatedAt: now,
  );
}

Future<ChapterDraftSnapshot?> recordLatestAuthorRevision(
  String chapterId,
  String content,
) async {
  final database = await getDatabase();
  final rows = await database.rawQuery('''
    SELECT * FROM chapter_drafts WHERE chapter_id = ?
    ORDER BY created_at DESC, rowid DESC LIMIT 1
  ''', [chapterId]);
  if (rows.isEmpty) return null;
  final latest = _map(rows.first);
  if (content == latest.aiDraft) {
    if (latest.status != ChapterDraftStatus.revised) return latest;
    final updatedAt = nowIso();
    await database.update(
      'chapter_drafts',
      {'author_revision': null, 'status': 'generated', 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [latest.id],
    );
    return ChapterDraftSnapshot(
      id: latest.id,
      projectId: latest.projectId,
      chapterId: latest.chapterId,
      styleProfileId: latest.styleProfileId,
      aiDraft: latest.aiDraft,
      status: ChapterDraftStatus.generated,
      createdAt: latest.createdAt,
      updatedAt: updatedAt,
    );
  }
  if (content == latest.authorRevision) return latest;
  final updatedAt = nowIso();
  await database.update(
    'chapter_drafts',
    {'author_revision': content, 'status': 'revised', 'updated_at': updatedAt},
    where: 'id = ?',
    whereArgs: [latest.id],
  );
  return ChapterDraftSnapshot(
    id: latest.id,
    projectId: latest.projectId,
    chapterId: latest.chapterId,
    styleProfileId: latest.styleProfileId,
    aiDraft: latest.aiDraft,
    authorRevision: content,
    status: ChapterDraftStatus.revised,
    createdAt: latest.createdAt,
    updatedAt: updatedAt,
  );
}

Future<ChapterDraftSnapshot?> getPendingChapterStyleEvolution(String chapterId) async {
  final database = await getDatabase();
  final rows = await database.rawQuery('''
    SELECT * FROM chapter_drafts
    WHERE id = (
      SELECT id FROM chapter_drafts WHERE chapter_id = ?
      ORDER BY created_at DESC, rowid DESC LIMIT 1
    ) AND status = 'revised'
      AND author_revision IS NOT NULL
      AND author_revision <> ai_draft
  ''', [chapterId]);
  return rows.isEmpty ? null : _map(rows.first);
}

Future<void> markChapterStyleEvolved(String id) async {
  final database = await getDatabase();
  final changes = await database.update(
    'chapter_drafts',
    {'status': 'evolved', 'updated_at': nowIso()},
    where: "id = ? AND status = 'revised'",
    whereArgs: [id],
  );
  if (changes != 1) throw Exception('待进化的章节原稿不存在');
}