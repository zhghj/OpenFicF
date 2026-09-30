import 'dart:convert';

import '../core/utils.dart';
import '../story_models.dart';
import 'database.dart';

Future<ProjectControls> getProjectControls(String projectId) async {
  final db = await getDatabase();
  final rows = await db.query('project_controls',
      where: 'project_id = ?', whereArgs: [projectId], limit: 1);
  if (rows.isEmpty) return const ProjectControls();
  try {
    final decoded = json.decode(rows.first['controls_json'] as String);
    if (decoded is Map) {
      return ProjectControls.fromJson(decoded.map((key, value) => MapEntry('$key', value)));
    }
  } catch (_) {}
  return const ProjectControls();
}

Future<void> saveProjectControls(String projectId, ProjectControls controls) async {
  final db = await getDatabase();
  final payload = json.encode(controls.toJson());
  final updated = await db.update(
    'project_controls',
    {'controls_json': payload, 'updated_at': nowIso()},
    where: 'project_id = ?',
    whereArgs: [projectId],
  );
  if (updated == 0) {
    await db.insert('project_controls', {
      'project_id': projectId,
      'controls_json': payload,
      'updated_at': nowIso(),
    });
  }
}