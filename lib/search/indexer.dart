import '../core/utils.dart';
import '../data/database.dart';
import '../data/repositories.dart';
import '../models.dart';
import '../settings/config.dart';

/// 本地检索。OpenFicM 在手机上跑 GGUF 嵌入与重排模型；
/// Flutter 首版使用同一套 vector_chunks 表结构做词频加权检索，
/// 离线可用，且未来可替换为设备端嵌入模型而不影响上层接口。
class IndexProgress {
  final int completed;
  final int total;
  final String title;

  const IndexProgress({required this.completed, required this.total, required this.title});
}

class IndexSummary {
  final int sourceCount;
  final int indexedSources;
  final int chunkCount;

  const IndexSummary({
    required this.sourceCount,
    required this.indexedSources,
    required this.chunkCount,
  });
}

class _IndexSource {
  final String type;
  final String id;
  final String title;
  final String content;
  final String updatedAt;

  const _IndexSource({
    required this.type,
    required this.id,
    required this.title,
    required this.content,
    required this.updatedAt,
  });
}

List<String> splitIntoChunks(String text, int size, int overlap) {
  final normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return [];
  final chunks = <String>[];
  final step = (size - overlap) < 1 ? 1 : (size - overlap);
  for (var start = 0; start < normalized.length; start += step) {
    final end = start + size;
    final chunk = normalized.substring(start, end > normalized.length ? normalized.length : end).trim();
    if (chunk.isNotEmpty) chunks.add(chunk);
    if (end >= normalized.length) break;
  }
  return chunks;
}

Future<List<_IndexSource>> _listIndexSources(String projectId) async {
  final chapters = await listChapters(projectId);
  final characters = await listCharacters(projectId);
  final worldInfo = await getOrCreateWorldInfo(projectId);
  final worldEntries = await listWorldInfoEntries(worldInfo.id);
  return [
    for (final chapter in chapters)
      _IndexSource(
        type: 'chapter',
        id: chapter.id,
        title: chapter.title,
        content: chapter.content,
        updatedAt: chapter.updatedAt,
      ),
    for (final character in characters)
      _IndexSource(
        type: 'character',
        id: character.id,
        title: character.name,
        content: character.description,
        updatedAt: character.updatedAt,
      ),
    for (final entry in worldEntries)
      if (entry.isEnabled)
        _IndexSource(
          type: 'world-entry',
          id: entry.id,
          title: entry.name,
          content: entry.content,
          updatedAt: entry.updatedAt,
        ),
  ].where((source) => source.content.trim().isNotEmpty).toList();
}

Future<int> _replaceSourceChunks(
  String projectId,
  _IndexSource source,
  IndexSettings settings,
) async {
  final db = await getDatabase();
  final texts = splitIntoChunks(source.content, settings.chunkSize, settings.chunkOverlap);
  await db.transaction((transaction) async {
    await transaction.delete('vector_chunks',
        where: 'project_id = ? AND source_id = ?', whereArgs: [projectId, source.id]);
    for (var index = 0; index < texts.length; index += 1) {
      await transaction.insert('vector_chunks', {
        'id': createId(),
        'project_id': projectId,
        'source_type': source.type,
        'source_id': source.id,
        'chunk_index': index,
        'title': source.title,
        'content': texts[index],
        'embedding': null,
        'source_updated_at': source.updatedAt,
      });
    }
  });
  return texts.length;
}

Future<IndexSummary> indexProject(
  String projectId, {
  bool force = false,
  void Function(IndexProgress progress)? onProgress,
}) async {
  final settings = await getIndexSettings();
  if (!settings.enabled) throw Exception('本地索引已关闭');
  final db = await getDatabase();
  final sources = await _listIndexSources(projectId);
  final currentSourceIds = sources.map((source) => source.id).toSet();
  final indexedRows = await db.rawQuery('''
    SELECT source_id, MAX(source_updated_at) AS source_updated_at
    FROM vector_chunks WHERE project_id = ? GROUP BY source_id
  ''', [projectId]);
  final indexedBySource = <String, String>{
    for (final row in indexedRows) row['source_id'] as String: (row['source_updated_at'] as String?) ?? '',
  };
  final removedIds = indexedRows
      .map((row) => row['source_id'] as String)
      .where((id) => !currentSourceIds.contains(id))
      .toList();
  for (final sourceId in removedIds) {
    await db.delete('vector_chunks',
        where: 'project_id = ? AND source_id = ?', whereArgs: [projectId, sourceId]);
  }
  final changed = sources
      .where((source) => force || indexedBySource[source.id] != source.updatedAt)
      .toList();
  var chunkCount = 0;
  for (var index = 0; index < changed.length; index += 1) {
    final source = changed[index];
    onProgress?.call(IndexProgress(completed: index, total: changed.length, title: source.title));
    chunkCount += await _replaceSourceChunks(projectId, source, settings);
    onProgress?.call(IndexProgress(completed: index + 1, total: changed.length, title: source.title));
  }
  final countRow = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM vector_chunks WHERE project_id = ?', [projectId]);
  return IndexSummary(
    sourceCount: sources.length,
    indexedSources: changed.length,
    chunkCount: (countRow.first['total'] as num?)?.toInt() ?? chunkCount,
  );
}

Future<({int sources, int chunks})> getProjectIndexStats(String projectId) async {
  final db = await getDatabase();
  final row = await db.rawQuery('''
    SELECT COUNT(DISTINCT source_id) AS sources, COUNT(*) AS chunks
    FROM vector_chunks WHERE project_id = ?
  ''', [projectId]);
  final first = row.first;
  return (
    sources: (first['sources'] as num?)?.toInt() ?? 0,
    chunks: (first['chunks'] as num?)?.toInt() ?? 0,
  );
}

Future<void> clearProjectIndex(String projectId) async {
  final db = await getDatabase();
  await db.delete('vector_chunks', where: 'project_id = ?', whereArgs: [projectId]);
}

List<String> _termsOf(String query) {
  return query
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}_]+', unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList();
}

double _scoreChunk(String content, List<String> terms) {
  if (terms.isEmpty) return 0;
  final lower = content.toLowerCase();
  var matched = 0;
  var total = 0;
  for (final term in terms) {
    final occurrences = RegExp(RegExp.escape(term)).allMatches(lower).length;
    if (occurrences > 0) matched += 1;
    total += occurrences;
  }
  if (matched == 0) return 0;
  final coverage = matched / terms.length;
  return coverage * 2 + (total / (total + 6));
}

Future<List<LocalSearchResult>> searchProjectKnowledge(String projectId, String query) async {
  final normalized = query.trim();
  if (normalized.isEmpty) return [];
  final settings = await getIndexSettings();
  if (!settings.enabled) return [];
  await indexProject(projectId);
  final db = await getDatabase();
  final rows = await db.query('vector_chunks', where: 'project_id = ?', whereArgs: [projectId]);
  if (rows.isEmpty) return [];
  final terms = _termsOf(normalized);
  final candidates = <LocalSearchResult>[];
  for (final row in rows) {
    final content = row['content'] as String? ?? '';
    final title = row['title'] as String? ?? '';
    final score = _scoreChunk('$title\n$content', terms);
    if (score <= 0) continue;
    candidates.add(LocalSearchResult(
      id: row['id'] as String,
      sourceType: row['source_type'] as String,
      sourceId: row['source_id'] as String,
      title: title,
      content: content,
      score: score,
    ));
  }
  candidates.sort((left, right) => right.score.compareTo(left.score));
  final limit = candidates.length < settings.retrievalTopK ? candidates.length : settings.retrievalTopK;
  return candidates.sublist(0, limit);
}