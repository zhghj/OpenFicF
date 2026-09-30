import 'dart:convert';

import '../core/utils.dart';
import '../story_models.dart';
import 'database.dart';

Observation _map(Map<String, Object?> row) {
  List<String> evidence = const [];
  final raw = row['evidence_json'] as String?;
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = json.decode(raw);
      if (decoded is List) evidence = decoded.whereType<String>().toList();
    } catch (_) {}
  }
  return Observation(
    id: row['id'] as String,
    projectId: row['project_id'] as String,
    chapterId: row['chapter_id'] as String?,
    code: row['code'] as String,
    summary: row['summary'] as String,
    evidence: evidence,
    assessment: row['assessment'] as String,
    category: row['category'] as String?,
    createdAt: row['created_at'] as String,
  );
}

Future<List<Observation>> listProjectObservations(String projectId) async {
  final db = await getDatabase();
  final rows = await db.query('chapter_observations',
      where: 'project_id = ?', whereArgs: [projectId], orderBy: 'created_at DESC');
  return rows.map(_map).toList();
}

Future<List<Observation>> listChapterObservations(String chapterId) async {
  final db = await getDatabase();
  final rows = await db.query('chapter_observations',
      where: 'chapter_id = ?', whereArgs: [chapterId], orderBy: 'created_at DESC');
  return rows.map(_map).toList();
}

Future<void> replaceChapterObservations(
  String projectId,
  String? chapterId,
  List<({String code, String summary, List<String> evidence, String assessment, String? category})> observations,
) async {
  final db = await getDatabase();
  await db.transaction((txn) async {
    if (chapterId != null) {
      await txn.delete('chapter_observations', where: 'chapter_id = ?', whereArgs: [chapterId]);
    }
    for (final observation in observations) {
      await txn.insert('chapter_observations', {
        'id': createId(),
        'project_id': projectId,
        'chapter_id': chapterId,
        'code': observation.code,
        'summary': observation.summary,
        'evidence_json': json.encode(observation.evidence),
        'assessment': observation.assessment,
        'category': observation.category,
        'created_at': nowIso(),
      });
    }
  });
}

Future<void> deleteObservation(String id) async {
  final db = await getDatabase();
  await db.delete('chapter_observations', where: 'id = ?', whereArgs: [id]);
}