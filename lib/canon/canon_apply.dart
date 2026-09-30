import '../canon_models.dart';
import '../data/canon_repositories.dart';
import '../data/note_repositories.dart';
import '../data/repositories.dart';

String canonEntryContent(CanonEntry entry) {
  final buffer = StringBuffer();
  if (entry.summary.trim().isNotEmpty) buffer.writeln(entry.summary.trim());
  if (entry.detail.trim().isNotEmpty) buffer.writeln('\n${entry.detail.trim()}');
  if (entry.evidence.trim().isNotEmpty) buffer.writeln('\n（正典依据：${entry.evidence.trim()}）');
  return buffer.toString().trim();
}

/// 把一条正典条目应用到对应资料：角色卡→角色库、世界观→世界书、其余→笔记。
/// 已应用过的条目会更新原目标，并把目标 id 记录回条目。
Future<({String appliedType, String appliedId})> applyCanonEntry({
  required String projectId,
  required CanonEntry entry,
}) async {
  final content = canonEntryContent(entry);
  if (entry.category == CanonCategory.character) {
    if (entry.appliedType == 'character' && entry.appliedId != null) {
      await saveCharacter(
        id: entry.appliedId,
        projectId: projectId,
        name: entry.title,
        description: content,
      );
      return (appliedType: 'character', appliedId: entry.appliedId!);
    }
    final character = await saveCharacter(
      projectId: projectId,
      name: entry.title,
      description: content,
    );
    await markCanonEntryApplied(entry.id, 'character', character.id);
    return (appliedType: 'character', appliedId: character.id);
  }
  if (entry.category == CanonCategory.world) {
    final worldInfo = await getOrCreateWorldInfo(projectId);
    if (entry.appliedType == 'world-entry' && entry.appliedId != null) {
      await saveWorldInfoEntry(
        id: entry.appliedId,
        worldInfoId: worldInfo.id,
        name: entry.title,
        content: content,
      );
      return (appliedType: 'world-entry', appliedId: entry.appliedId!);
    }
    final saved = await saveWorldInfoEntry(
      worldInfoId: worldInfo.id,
      name: entry.title,
      content: content,
    );
    await markCanonEntryApplied(entry.id, 'world-entry', saved.id);
    return (appliedType: 'world-entry', appliedId: saved.id);
  }
  if (entry.appliedType == 'note' && entry.appliedId != null) {
    await updateNote(id: entry.appliedId!, title: entry.title, content: content);
    return (appliedType: 'note', appliedId: entry.appliedId!);
  }
  final note = await createNote(
    projectId: projectId,
    title: entry.title,
    content: content,
  );
  await markCanonEntryApplied(entry.id, 'note', note.id);
  return (appliedType: 'note', appliedId: note.id);
}