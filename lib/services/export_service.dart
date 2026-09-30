import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';

enum ExportScope { chapter, volume, book }

String _safeFileName(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_')
      .trim();
  return cleaned.isEmpty ? 'OpenFicF' : (cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned);
}

String _renderChapter(Chapter chapter) {
  final content = chapter.content.trim().isEmpty ? '（本章暂无正文）' : chapter.content.trim();
  return '### ${chapter.title}\n\n$content\n';
}

Future<File> _writeCacheFile(String fileName, String content) async {
  final directory = await getTemporaryDirectory();
  final file = File(p.join(directory.path, fileName));
  if (await file.exists()) await file.delete();
  await file.writeAsString(content, flush: true);
  return file;
}

Future<void> _shareFile(File file, String mimeType, String dialogTitle) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: mimeType)],
    text: dialogTitle,
  ));
}

Future<void> exportNovel({
  required Project project,
  required List<Volume> volumes,
  required List<Chapter> chapters,
  required ExportScope scope,
  String? chapterId,
  String? volumeId,
}) async {
  final orderedVolumes = [...volumes]..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  final orderedChapters = [...chapters]..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  var title = project.title;
  var markdown = '# ${project.title}\n\n';
  if (project.description.trim().isNotEmpty) markdown += '${project.description.trim()}\n\n';

  if (scope == ExportScope.chapter) {
    Chapter? chapter;
    for (final item in orderedChapters) {
      if (item.id == chapterId) {
        chapter = item;
        break;
      }
    }
    if (chapter == null) throw Exception('当前章节不存在，无法导出');
    title = chapter.title;
    markdown += _renderChapter(chapter);
  } else {
    final selected = scope == ExportScope.volume
        ? orderedVolumes.where((volume) => volume.id == volumeId).toList()
        : orderedVolumes;
    if (selected.isEmpty) {
      throw Exception(scope == ExportScope.volume ? '当前卷不存在，无法导出' : '作品没有可导出的卷');
    }
    if (scope == ExportScope.volume) title = selected.first.title;
    for (final volume in selected) {
      markdown += '## ${volume.title}\n\n';
      final volumeChapters = orderedChapters.where((chapter) => chapter.volumeId == volume.id).toList();
      markdown += volumeChapters.isEmpty
          ? '（本卷暂无章节）\n\n'
          : '${volumeChapters.map(_renderChapter).join('\n')}\n';
    }
  }

  final scopeLabel = scope == ExportScope.chapter ? '章节' : scope == ExportScope.volume ? '卷' : '全书';
  final timestamp = DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp('[.:]'), '-')
      .replaceAll('T', '-')
      .replaceAll('Z', '');
  final fileName =
      '${_safeFileName(project.title)}-${_safeFileName(title)}-$scopeLabel-$timestamp.md';
  final file = await _writeCacheFile(fileName, markdown);
  await _shareFile(file, 'text/markdown', '导出$scopeLabel');
}

String _dateStamp() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

String _libraryFileName(String projectTitle, String label, bool json) {
  return '${_safeFileName(projectTitle)}_${label}_${_dateStamp()}.${json ? 'json' : 'md'}';
}

Future<void> exportCharacters(Project project, List<Character> characters, bool json) async {
  if (characters.isEmpty) throw Exception('没有可导出的角色');
  final exportedAt = DateTime.now().toIso8601String();
  final content = json
      ? const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': '1.0',
          'type': 'openficf.characters',
          'projectId': project.id,
          'exportedAt': exportedAt,
          'entries': characters
              .map((character) => {
                    'id': character.id,
                    'projectId': character.projectId,
                    'name': character.name,
                    'description': character.description,
                    'imagePath': character.imagePath,
                    'isFavorited': character.isFavorited,
                    'createdAt': character.createdAt,
                    'updatedAt': character.updatedAt,
                  })
              .toList(),
        })
      : '# ${project.title} · 角色库\n\n- 作品 ID：${project.id}\n- 导出时间：$exportedAt\n\n'
          '${characters.map(_renderCharacterMarkdown).join('\n')}';
  final file = await _writeCacheFile(
    _libraryFileName(project.title, '角色库', json),
    content,
  );
  await _shareFile(file, json ? 'application/json' : 'text/markdown', '导出角色库');
}

String _renderCharacterMarkdown(Character character) {
  return '## ${character.name}\n\n- ID：${character.id}\n- 收藏：${character.isFavorited ? '是' : '否'}\n'
      '- 创建时间：${character.createdAt}\n- 更新时间：${character.updatedAt}\n\n'
      '### 角色设定\n\n${character.description.isEmpty ? '暂无' : character.description}\n';
}

Future<void> exportWorldInfo(
  Project project,
  WorldInfo worldInfo,
  List<WorldInfoEntry> entries,
  bool json,
) async {
  if (entries.isEmpty) throw Exception('没有可导出的世界书条目');
  final exportedAt = DateTime.now().toIso8601String();
  final content = json
      ? const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': '1.0',
          'type': 'openficf.world-info',
          'projectId': project.id,
          'exportedAt': exportedAt,
          'worldInfo': {
            'id': worldInfo.id,
            'name': worldInfo.name,
            'description': worldInfo.description,
          },
          'entries': entries
              .map((entry) => {
                    'id': entry.id,
                    'uid': entry.uid,
                    'name': entry.name,
                    'order': entry.order,
                    'content': entry.content,
                    'tokenCount': entry.tokenCount,
                    'isEnabled': entry.isEnabled,
                    'createdAt': entry.createdAt,
                    'updatedAt': entry.updatedAt,
                  })
              .toList(),
        })
      : '# ${project.title} · ${worldInfo.name}\n\n- 作品 ID：${project.id}\n'
          '- 世界书 ID：${worldInfo.id}\n- 导出时间：$exportedAt\n\n'
          '${worldInfo.description.isEmpty ? '' : '${worldInfo.description}\n\n'}'
          '${entries.map(_renderWorldEntryMarkdown).join('\n')}';
  final file = await _writeCacheFile(
    _libraryFileName(project.title, '世界书', json),
    content,
  );
  await _shareFile(file, json ? 'application/json' : 'text/markdown', '导出世界书');
}

String _renderWorldEntryMarkdown(WorldInfoEntry entry) {
  return '## ${entry.name}\n\n- ID：${entry.id}\n- UID：${entry.uid}\n- 启用：${entry.isEnabled ? '是' : '否'}\n'
      '- Token 数：${entry.tokenCount}\n- 更新时间：${entry.updatedAt}\n\n'
      '### 条目内容\n\n${entry.content.isEmpty ? '暂无' : entry.content}\n';
}