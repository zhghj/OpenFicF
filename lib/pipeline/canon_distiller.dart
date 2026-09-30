import 'dart:math';

import '../canon/canon_source_library.dart';
import '../canon_models.dart';
import '../data/canon_repositories.dart';
import '../llm/client.dart';
import '../llm/llm_types.dart';
import '../models.dart';
import 'canon_prompts.dart';
import 'chapter_pipeline.dart';

class CanonDistillProgress {
  final String stage;
  final int completed;
  final int total;
  final String label;

  const CanonDistillProgress({
    required this.stage,
    required this.completed,
    required this.total,
    required this.label,
  });
}

class CanonDistillResult {
  final CanonSource source;
  final int added;
  final int merged;
  final int processedChunks;
  final bool reachedEnd;

  const CanonDistillResult({
    required this.source,
    required this.added,
    required this.merged,
    required this.processedChunks,
    required this.reachedEnd,
  });
}

final RegExp _headingPattern = RegExp(
  r'^[ \t]{0,4}(?:第[0-9零〇一二两三四五六七八九十百千万]+[章节回][^\n]{0,60})$',
  multiLine: true,
);

const int _chunkCharacterTarget = 2800;
const int _maxChunkCharacters = 4000;

/// 把正典正文切成可分批蒸馏的片段：优先按章节，否则按段落聚合。
List<ParsedCanonChunk> splitCanonChunks(String text, {int target = _chunkCharacterTarget}) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\n{4,}'), '\n\n\n').trim();
  if (normalized.isEmpty) return [];

  final headingStarts = <int>[];
  for (final match in _headingPattern.allMatches(normalized)) {
    if (headingStarts.isEmpty || match.start > headingStarts.last) headingStarts.add(match.start);
  }

  if (headingStarts.length >= 3) {
    final chunks = <ParsedCanonChunk>[];
    for (var index = 0; index < headingStarts.length; index += 1) {
      final start = headingStarts[index];
      final end = index + 1 < headingStarts.length ? headingStarts[index + 1] : normalized.length;
      final section = normalized.substring(start, end).trim();
      if (section.isEmpty) continue;
      final heading = section.split('\n').first.trim();
      if (section.length <= _maxChunkCharacters) {
        chunks.add(ParsedCanonChunk(label: heading, text: section));
      } else {
        final parts = _packParagraphs(section, target);
        for (var part = 0; part < parts.length; part += 1) {
          chunks.add(ParsedCanonChunk(label: '$heading（${part + 1}）', text: parts[part]));
        }
      }
    }
    return chunks;
  }

  final parts = _packParagraphs(normalized, target);
  return [
    for (var index = 0; index < parts.length; index += 1)
      ParsedCanonChunk(label: '片段 ${index + 1}', text: parts[index]),
  ];
}

List<String> _packParagraphs(String text, int target) {
  final paragraphs = text.split(RegExp(r'\n\s*\n'));
  final chunks = <String>[];
  final buffer = StringBuffer();
  for (final paragraph in paragraphs) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) continue;
    if (buffer.isNotEmpty && buffer.length + trimmed.length + 2 > target) {
      chunks.add(buffer.toString().trim());
      buffer.clear();
    }
    if (trimmed.length > _maxChunkCharacters) {
      if (buffer.isNotEmpty) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      for (var start = 0; start < trimmed.length; start += target) {
        final end = min(start + target, trimmed.length);
        chunks.add(trimmed.substring(start, end).trim());
      }
      continue;
    }
    if (buffer.isNotEmpty) buffer.write('\n\n');
    buffer.write(trimmed);
  }
  if (buffer.isNotEmpty) chunks.add(buffer.toString().trim());
  return chunks;
}

List<Map<String, dynamic>> _items(Map<String, dynamic> json, String key) {
  final raw = json[key];
  if (raw is! List) return [];
  return raw.whereType<Map>().map((item) => item.map((k, v) => MapEntry('$k', v))).toList();
}

String _text(Map<String, dynamic> item, String key) => '${item[key] ?? ''}'.trim();

const Map<String, CanonCategory> _categoryKeys = {
  'characters': CanonCategory.character,
  'timeline': CanonCategory.timeline,
  'world': CanonCategory.world,
  'relationships': CanonCategory.relationship,
  'other': CanonCategory.other,
};

/// 处理单个片段：调用模型抽取正典条目并写入。模型无有效输出时返回 ok=false，不阻塞后续。
Future<({int added, int merged, bool ok})> _processChunk({
  required CanonSource source,
  required ModelSelection selection,
  required ParsedCanonChunk chunk,
  required List<({String title, List<String> aliases})> knownNames,
}) async {
  Map<String, dynamic>? json;
  try {
    final turn = await callModel(
      selection,
      [
        AgentMessage(role: 'system', content: buildCanonExtractSystemPrompt()),
        AgentMessage(
          role: 'user',
          content: buildCanonExtractUserPrompt(
            sourceTitle: source.title,
            label: chunk.label,
            chunk: chunk.text,
            knownNames: knownNames,
          ),
        ),
      ],
      const [],
      ModelCallOptions(minOutputTokens: 4096),
    );
    json = extractJsonObject(turn.content);
  } catch (_) {
    json = null;
  }
  if (json == null) return (added: 0, merged: 0, ok: false);

  var added = 0;
  var merged = 0;
  for (final entry in _categoryKeys.entries) {
    final category = entry.value;
    for (final item in _items(json, entry.key)) {
      final title = _text(item, 'title');
      if (title.length < 2) continue;
      final aliases = (item['aliases'] as List<dynamic>? ?? [])
          .whereType<String>()
          .map((alias) => alias.trim())
          .where((alias) => alias.isNotEmpty)
          .toList();
      final created = await _upsertEntry(
        projectId: source.projectId,
        sourceId: source.id,
        category: category,
        title: title,
        summary: _text(item, 'summary'),
        detail: _text(item, 'detail'),
        evidence: _text(item, 'evidence'),
        aliases: aliases,
      );
      if (created) {
        added += 1;
      } else {
        merged += 1;
      }
    }
  }
  return (added: added, merged: merged, ok: true);
}

/// 分片蒸馏（每批固定片段数），保留原有即时行为。
Future<CanonDistillResult> distillCanonBatch({
  required CanonSource source,
  required ModelSelection selection,
  int batchSize = 3,
  bool restart = false,
  void Function(CanonDistillProgress progress)? onProgress,
}) async {
  void report(String stage, int completed, int total, String label) =>
      onProgress?.call(CanonDistillProgress(stage: stage, completed: completed, total: total, label: label));

  report('reading', 0, 1, '正在读取原作并切分片段');
  final text = await readCanonText(source);
  final chunks = splitCanonChunks(text);
  if (chunks.isEmpty) throw Exception('原作没有可蒸馏的正文');
  final start = restart ? 0 : source.coveredUntil.clamp(0, chunks.length);
  final end = min(start + batchSize, chunks.length);
  if (start >= chunks.length) {
    await updateCanonSourceProgress(source.id, coveredUntil: chunks.length, chunkCount: chunks.length);
    return CanonDistillResult(
      source: source.copyWith(coveredUntil: chunks.length, chunkCount: chunks.length),
      added: 0,
      merged: 0,
      processedChunks: 0,
      reachedEnd: true,
    );
  }

  var added = 0;
  var merged = 0;
  final knownNames = await listCanonNamesForSource(source.id);
  for (var index = start; index < end; index += 1) {
    report('analyzing', index - start, end - start, '正在蒸馏 ${chunks[index].label}');
    final result = await _processChunk(
      source: source,
      selection: selection,
      chunk: chunks[index],
      knownNames: knownNames,
    );
    added += result.added;
    merged += result.merged;
    await updateCanonSourceProgress(source.id, coveredUntil: index + 1, chunkCount: chunks.length);
    report('analyzing', index - start + 1, end - start,
        result.ok ? '已处理 ${chunks[index].label}' : '${chunks[index].label} 未返回有效 JSON，已跳过');
  }

  report('done', end - start, end - start, '本轮蒸馏完成');
  return CanonDistillResult(
    source: source.copyWith(coveredUntil: end, chunkCount: chunks.length),
    added: added,
    merged: merged,
    processedChunks: end - start,
    reachedEnd: end >= chunks.length,
  );
}

/// 蒸馏整部正典：从断点开始处理所有剩余片段，支持并发、暂停/继续与取消。
/// [onBeforeStep] 在每个批次前调用，用于配合任务池的暂停/取消。
Future<CanonDistillResult> distillCanonAll({
  required CanonSource source,
  required ModelSelection selection,
  int parallelism = 2,
  Future<void> Function()? onBeforeStep,
  void Function(CanonDistillProgress progress)? onProgress,
  void Function(String message)? onLog,
}) async {
  void report(String stage, int completed, int total, String label) =>
      onProgress?.call(CanonDistillProgress(stage: stage, completed: completed, total: total, label: label));

  report('reading', 0, 1, '正在读取原作并切分片段');
  final text = await readCanonText(source);
  final chunks = splitCanonChunks(text);
  if (chunks.isEmpty) throw Exception('原作没有可蒸馏的正文');

  final start = source.coveredUntil.clamp(0, chunks.length);
  if (start >= chunks.length) {
    onLog?.call('已无待蒸馏片段，共 ${chunks.length} 片');
    return CanonDistillResult(
      source: source.copyWith(coveredUntil: chunks.length, chunkCount: chunks.length),
      added: 0,
      merged: 0,
      processedChunks: 0,
      reachedEnd: true,
    );
  }

  var covered = start;
  var added = 0;
  var merged = 0;
  final batchSize = parallelism < 1 ? 1 : parallelism;
  onLog?.call('开始蒸馏《${source.title}》：共 ${chunks.length} 片，从第 ${start + 1} 片继续，并发 $batchSize');
  report('analyzing', covered, chunks.length, '准备蒸馏 ${chunks.length - start} 个片段');

  while (covered < chunks.length) {
    if (onBeforeStep != null) await onBeforeStep();
    final end = min(covered + batchSize, chunks.length);
    final batch = chunks.sublist(covered, end);
    // 每批刷新已知实体，让后续片段复用规范名称，减少重复卡。
    final knownNames = await listCanonNamesForSource(source.id);
    onLog?.call('处理第 ${covered + 1}-$end 片：${batch.map((chunk) => chunk.label).join('、')}');
    final results = await Future.wait(
      batch.map((chunk) => _processChunk(
            source: source,
            selection: selection,
            chunk: chunk,
            knownNames: knownNames,
          )),
    );
    for (var index = 0; index < results.length; index += 1) {
      final result = results[index];
      added += result.added;
      merged += result.merged;
      onLog?.call(
        '${batch[index].label}：${result.ok ? '新增 ${result.added}、合并 ${result.merged}' : '未返回有效 JSON，已跳过'}',
      );
    }
    covered = end;
    await updateCanonSourceProgress(source.id, coveredUntil: covered, chunkCount: chunks.length);
    report('analyzing', covered, chunks.length, '已蒸馏 $covered/${chunks.length} 片');
  }

  onLog?.call('整部蒸馏完成：新增 $added 条，合并 $merged 条');
  report('done', chunks.length, chunks.length, '整部蒸馏完成');
  return CanonDistillResult(
    source: source.copyWith(coveredUntil: covered, chunkCount: chunks.length),
    added: added,
    merged: merged,
    processedChunks: covered - start,
    reachedEnd: true,
  );
}

String _entryMaterial(CanonEntry entry) => [
      '### ${entry.title}',
      if (entry.aliases.isNotEmpty) 'aliases: ${entry.aliases.join('、')}',
      if (entry.summary.trim().isNotEmpty) 'summary: ${entry.summary}',
      if (entry.detail.trim().isNotEmpty) 'detail: ${entry.detail}',
      if (entry.evidence.trim().isNotEmpty) 'evidence: ${entry.evidence}',
    ].join('\n');

/// 用 AI 把一条（或已合并的）条目重新整理为单张复合条目。
Future<CanonEntry> refineCanonEntryWithAI({
  required CanonEntry entry,
  required ModelSelection selection,
  List<CanonEntry> related = const [],
}) async {
  final material = [entry, ...related].map(_entryMaterial).join('\n\n');
  final turn = await callModel(
    selection,
    [
      AgentMessage(role: 'system', content: buildCanonMergeSystemPrompt()),
      AgentMessage(
        role: 'user',
        content: buildCanonMergeUserPrompt(
          categoryLabel: entry.category.label,
          material: material,
        ),
      ),
    ],
    const [],
    ModelCallOptions(minOutputTokens: 4096),
  );
  final json = extractJsonObject(turn.content);
  if (json == null) throw Exception('模型没有返回有效的归并 JSON');
  final title = '${json['title'] ?? entry.title}'.trim();
  final aliases = (json['aliases'] as List<dynamic>? ?? [])
      .whereType<String>()
      .map((alias) => alias.trim())
      .where((alias) => alias.isNotEmpty)
      .toList();
  await updateCanonEntry(
    entry.id,
    title: title.isEmpty ? null : title,
    summary: '${json['summary'] ?? entry.summary}',
    detail: '${json['detail'] ?? entry.detail}',
    evidence: '${json['evidence'] ?? entry.evidence}',
    aliases: aliases.isEmpty ? entry.aliases : aliases,
  );
  return (await getCanonEntry(entry.id)) ?? entry;
}

/// 返回 true 表示新建条目，false 表示合并进已有条目。
/// 按标题或别名匹配：同一实体的不同称呼会并入同一张卡，新称呼追加为别名。
Future<bool> _upsertEntry({
  required String projectId,
  required String sourceId,
  required CanonCategory category,
  required String title,
  required String summary,
  required String detail,
  required String evidence,
  List<String> aliases = const [],
}) async {
  final existing = await findCanonEntryByName(sourceId: sourceId, category: category, name: title);
  if (existing == null) {
    await createCanonEntry(
      projectId: projectId,
      sourceId: sourceId,
      category: category,
      title: title,
      summary: summary,
      detail: detail,
      evidence: evidence,
      aliases: aliases,
    );
    return true;
  }

  final nextAliases = <String>{...existing.aliases};
  for (final alias in aliases) {
    if (alias.trim().toLowerCase() != existing.title.trim().toLowerCase()) nextAliases.add(alias);
  }
  // 本片用别名作为 title 命中已有卡时，把该别名登记下来。
  if (title.trim().toLowerCase() != existing.title.trim().toLowerCase()) nextAliases.add(title);

  final detailAdds = detail.isNotEmpty && !_containsNormalized(existing.detail, detail);
  final nextDetail = detailAdds
      ? (existing.detail.trim().isEmpty ? detail : '${existing.detail.trim()}\n\n$detail')
      : null;
  await updateCanonEntry(
    existing.id,
    summary: existing.summary.trim().isEmpty && summary.isNotEmpty ? summary : null,
    detail: nextDetail,
    evidence: existing.evidence.trim().isEmpty && evidence.isNotEmpty ? evidence : null,
    aliases: nextAliases.toList(),
  );
  return false;
}

bool _containsNormalized(String haystack, String needle) {
  final probe = needle.replaceAll(RegExp(r'\s+'), '').trim();
  if (probe.isEmpty) return true;
  final source = haystack.replaceAll(RegExp(r'\s+'), '');
  return source.contains(probe.length > 30 ? probe.substring(0, 30) : probe);
}