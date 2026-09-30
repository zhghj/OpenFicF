import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/utils.dart';
import '../data/style_repositories.dart';
import '../models.dart';
import 'sampling.dart';

const int _maxImportBytes = 50 * 1024 * 1024;
const int _maxExtractedCharacters = 8000000;
const int _maxEpubTextEntryBytes = 4 * 1024 * 1024;
const int _maxEpubTotalTextBytes = 20 * 1024 * 1024;
const int _analysisPassageCharacters = 1400;
const int _analysisBatchSize = 6;
const int _minChapterHeadingCount = 8;
const String _libraryDirectoryName = 'style-library';

final RegExp _chapterHeadingPattern = RegExp(
  r'^[ \t]{0,4}(?:第[0-9零〇一二两三四五六七八九十百千万]+[章节回][^\n]{0,60}|(?:chapter|chap\.?)\s*\d+[^\n]{0,60})[ \t]*$',
  multiLine: true,
  caseSensitive: false,
);

class StyleAnalysisBatch {
  final String label;
  final int passageCount;
  final String text;

  const StyleAnalysisBatch({
    required this.label,
    required this.passageCount,
    required this.text,
  });
}

class StyleAnalysisPlan {
  final StyleUnitKind unitKind;
  final int totalUnits;
  final StyleSampleWindow? window;
  final String windowLabel;
  final List<StyleAnalysisBatch> batches;
  final int passageCount;

  const StyleAnalysisPlan({
    required this.unitKind,
    required this.totalUnits,
    required this.window,
    required this.windowLabel,
    required this.batches,
    required this.passageCount,
  });
}

Future<Directory> _libraryDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  final directory = Directory(p.join(documents.path, _libraryDirectoryName));
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

Future<File> _contentFile(String sourceId) async {
  final directory = await _libraryDirectory();
  return File(p.join(directory.path, '$sourceId.content.txt'));
}

String _extensionOf(String fileName) {
  final match = RegExp(r'\.([^.]+)$').firstMatch(fileName.trim());
  return match?.group(1)?.toLowerCase() ?? '';
}

String _formatForExtension(String extension) {
  if (extension == 'txt') return 'txt';
  if (extension == 'md' || extension == 'markdown') return 'markdown';
  if (extension == 'epub') return 'epub';
  throw Exception('仅支持 TXT、Markdown 和 EPUB 文件');
}

String decodeText(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  final utf8Text = utf8.decode(bytes, allowMalformed: true);
  final utf8ReplacementCount = '\uFFFD'.allMatches(utf8Text).length;
  if (utf8ReplacementCount == 0) return utf8Text;
  try {
    final gbText = gbk.decode(bytes);
    final gbReplacementCount = '\uFFFD'.allMatches(gbText).length;
    return gbReplacementCount < utf8ReplacementCount ? gbText : utf8Text;
  } catch (_) {
    return utf8Text;
  }
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final codeUnits = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codeUnits.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(codeUnits);
}

String normalizeText(String value) {
  return value
      .replaceAll(RegExp(r'^\uFEFF'), '')
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .replaceAll(RegExp(r'[\t\u00A0]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{4,}'), '\n\n\n')
      .trim();
}

String _archivePath(String basePath, String relativePath) {
  final decoded = Uri.decodeComponent(Uri.decodeFull(relativePath.split('#').first));
  final parts = '$basePath/$decoded'.split('/');
  final normalized = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (normalized.isNotEmpty) normalized.removeLast();
    } else {
      normalized.add(part);
    }
  }
  return normalized.join('/');
}

Uint8List? _findArchiveEntry(Map<String, Uint8List> entries, String path) {
  final direct = entries[path];
  if (direct != null) return direct;
  final lowerPath = path.toLowerCase();
  for (final entry in entries.entries) {
    if (entry.key.toLowerCase() == lowerPath) return entry.value;
  }
  return null;
}

String _stripMarkup(String value) {
  return value
      .replaceAll(RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAllMapped(RegExp(r'&#x([\da-f]+);', caseSensitive: false),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(RegExp(r'&(nbsp|amp|lt|gt|quot|apos);', caseSensitive: false), (m) {
    switch (m.group(1)!.toLowerCase()) {
      case 'nbsp':
        return ' ';
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      default:
        return ' ';
    }
  });
}

String _extractMarkupText(String value) {
  return normalizeText(_stripMarkup(value));
}

({String? title, String text}) _extractEpub(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  var totalTextBytes = 0;
  final entries = <String, Uint8List>{};
  for (final entry in archive) {
    final name = entry.name;
    final lower = name.toLowerCase();
    final textEntry = lower == 'meta-inf/container.xml' ||
        RegExp(r'\.(opf|xhtml|html|htm|xml|ncx)$').hasMatch(lower);
    if (!textEntry) continue;
    if (entry.size > _maxEpubTextEntryBytes) throw Exception('EPUB 单个文本条目超过 4 MB 限制');
    totalTextBytes += entry.size;
    if (totalTextBytes > _maxEpubTotalTextBytes) throw Exception('EPUB 解压后的文本超过 20 MB 限制');
    entries[name] = Uint8List.fromList(entry.content as List<int>);
  }
  final containerBytes = _findArchiveEntry(entries, 'META-INF/container.xml');
  if (containerBytes == null) throw Exception('EPUB 缺少 META-INF/container.xml');
  final containerXml = decodeText(containerBytes);
  final rootFilePath = RegExp(r'full-path\s*=\s*"([^"]+)"').firstMatch(containerXml)?.group(1);
  if (rootFilePath == null) throw Exception('EPUB 没有声明内容包');
  final packageBytes = _findArchiveEntry(entries, rootFilePath);
  if (packageBytes == null) throw Exception('EPUB 内容包不存在');
  final packageXml = decodeText(packageBytes);

  String? title;
  final titleMatch = RegExp(r'<dc:title[^>]*>([\s\S]*?)</dc:title>', caseSensitive: false).firstMatch(packageXml);
  if (titleMatch != null) title = normalizeText(_stripMarkup(titleMatch.group(1)!));

  final basePath = rootFilePath.contains('/')
      ? rootFilePath.substring(0, rootFilePath.lastIndexOf('/'))
      : '';

  // manifest: id -> href
  final manifest = <String, String>{};
  for (final match in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(packageXml)) {
    final tag = match.group(0)!;
    final id = RegExp(r'id\s*=\s*"([^"]+)"').firstMatch(tag)?.group(1);
    final href = RegExp(r'href\s*=\s*"([^"]+)"').firstMatch(tag)?.group(1);
    if (id != null && href != null) manifest[id] = href;
  }
  final spineIds = <String>[];
  for (final match in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(packageXml)) {
    final idref = RegExp(r'idref\s*=\s*"([^"]+)"').firstMatch(match.group(0)!)?.group(1);
    if (idref != null) spineIds.add(idref);
  }

  final sections = <String>[];
  var accumulated = 0;
  for (final idref in spineIds) {
    final href = manifest[idref];
    if (href == null) continue;
    final entry = _findArchiveEntry(entries, _archivePath(basePath, href));
    if (entry == null) continue;
    final section = _extractMarkupText(decodeText(entry));
    if (section.isNotEmpty) {
      sections.add(section);
      accumulated += section.length;
      if (accumulated > _maxExtractedCharacters) {
        throw Exception('EPUB 提取后的正文超过 800 万字符限制');
      }
    }
  }
  final text = normalizeText(sections.join('\n\n'));
  if (text.isEmpty) throw Exception('EPUB 书脊中没有可读取的正文');
  return (title: title, text: text);
}

String _sourceTitle(String fileName) {
  final stripped = fileName.replaceAll(RegExp(r'\.[^.]+$'), '').trim();
  return stripped.isEmpty ? '未命名参考书' : stripped;
}

class ParsedDocument {
  final String format;
  final String? title;
  final String text;

  const ParsedDocument({required this.format, required this.title, required this.text});
}

/// 解析 TXT / Markdown / EPUB 字节为规范化正文，供参考书库与同人正典共用。
ParsedDocument parseDocumentBytes({required Uint8List bytes, required String fileName}) {
  final format = _formatForExtension(_extensionOf(fileName));
  if (bytes.length > _maxImportBytes) throw Exception('文件必须小于 50 MB');
  final extracted = format == 'epub'
      ? _extractEpub(bytes)
      : (title: null as String?, text: normalizeText(decodeText(bytes)));
  if (extracted.text.isEmpty) throw Exception('文件中没有可读取的正文');
  if (extracted.text.length > _maxExtractedCharacters) throw Exception('正文超过 800 万字符限制');
  return ParsedDocument(format: format, title: extracted.title, text: extracted.text);
}

Future<StyleSource?> importStyleSourceFromBytes({
  required Uint8List bytes,
  required String fileName,
}) async {
  final parsed = parseDocumentBytes(bytes: bytes, fileName: fileName);
  final format = parsed.format;
  final sizeBytes = bytes.length;
  final contentHash = sha256.convert(bytes).toString();
  final duplicate = await findStyleSourceByHash(contentHash);
  if (duplicate != null) throw Exception('《${duplicate.title}》已在参考书库中');
  final extracted = (title: parsed.title, text: parsed.text);
  final id = createId();
  final directory = await _libraryDirectory();
  final originalExtension = _extensionOf(fileName);
  final originalFile = File(p.join(directory.path, '$id${originalExtension.isEmpty ? '' : '.$originalExtension'}'));
  final normalizedFile = File(p.join(directory.path, '$id.content.txt'));
  try {
    await originalFile.writeAsBytes(bytes, flush: true);
    await normalizedFile.writeAsString(extracted.text, flush: true);
    return await createStyleSource(
      id: id,
      title: extracted.title ?? _sourceTitle(fileName),
      fileName: fileName,
      format: format,
      fileUri: originalFile.path,
      sizeBytes: sizeBytes,
      contentHash: contentHash,
      characterCount: extracted.text.length,
    );
  } catch (error) {
    if (await originalFile.exists()) await originalFile.delete();
    if (await normalizedFile.exists()) await normalizedFile.delete();
    rethrow;
  }
}

Future<String> readStyleSourceText(String sourceId) async {
  final source = await getStyleSource(sourceId);
  if (source == null) throw Exception('参考书不存在');
  final file = await _contentFile(source.id);
  if (!await file.exists()) throw Exception('参考书正文文件已丢失，请重新导入');
  return file.readAsString();
}

class _SourceOutline {
  final StyleUnitKind unitKind;
  final List<int> unitStarts;

  const _SourceOutline({required this.unitKind, required this.unitStarts});
}

_SourceOutline _sourceOutline(String text) {
  final chapterStarts = <int>[];
  for (final match in _chapterHeadingPattern.allMatches(text)) {
    final start = match.start;
    if (chapterStarts.isEmpty || start > chapterStarts.last) chapterStarts.add(start);
  }
  if (chapterStarts.length >= _minChapterHeadingCount) {
    return _SourceOutline(unitKind: StyleUnitKind.chapter, unitStarts: chapterStarts);
  }
  final unitStarts = <int>[];
  for (var start = 0; start < text.length; start += _analysisPassageCharacters) {
    final paragraphStart = text.lastIndexOf('\n', start);
    unitStarts.add(paragraphStart >= start - 500 ? paragraphStart + 1 : start);
  }
  return _SourceOutline(
    unitKind: StyleUnitKind.segment,
    unitStarts: unitStarts.isEmpty ? [0] : unitStarts,
  );
}

String _passageAt(String text, _SourceOutline outline, int index) {
  if (index >= outline.unitStarts.length) return '';
  final start = outline.unitStarts[index];
  final nextStart = index + 1 < outline.unitStarts.length ? outline.unitStarts[index + 1] : text.length;
  final end = nextStart < start + _analysisPassageCharacters ? nextStart : start + _analysisPassageCharacters;
  return text.substring(start, end).trim();
}

List<StyleAnalysisBatch> _buildBatches(
  String text,
  _SourceOutline outline,
  List<int> indices,
  String Function(int unitIndex) describe,
) {
  final selected = <({int unitIndex, String passage})>[];
  for (final unitIndex in indices) {
    final passage = _passageAt(text, outline, unitIndex);
    if (passage.isNotEmpty) selected.add((unitIndex: unitIndex, passage: passage));
  }
  if (selected.isEmpty) throw Exception('参考书中没有可分析的正文');
  final batchCount = (selected.length / _analysisBatchSize).ceil();
  return List<StyleAnalysisBatch>.generate(batchCount, (batchIndex) {
    final offset = batchIndex * _analysisBatchSize;
    final items = selected.sublist(
      offset,
      (offset + _analysisBatchSize) > selected.length ? selected.length : offset + _analysisBatchSize,
    );
    return StyleAnalysisBatch(
      label: '${describe(items.first.unitIndex)} 起的 ${items.length} 个样本',
      passageCount: items.length,
      text: items.map((item) => '[${describe(item.unitIndex)}]\n${item.passage}').join('\n\n'),
    );
  });
}

Future<StyleAnalysisPlan> readStyleSourceAnalysisPlan({
  required String sourceId,
  int? coveredUntil,
  StyleSampleWindow? window,
  Random? random,
}) async {
  final text = await readStyleSourceText(sourceId);
  final outline = _sourceOutline(text);
  final totalUnits = outline.unitStarts.length;
  final unitName = outline.unitKind == StyleUnitKind.chapter ? '章' : '段';
  String describe(int unitIndex) => '第 ${unitIndex + 1} $unitName';

  StyleAnalysisPlan buildPlan(StyleSampleWindow? selectedWindow) {
    final indices = selectedWindow != null
        ? List<int>.generate(selectedWindow.count, (index) => selectedWindow.start + index)
        : spreadIndices(totalUnits, analysisPassageCount);
    final batches = _buildBatches(text, outline, indices, describe);
    return StyleAnalysisPlan(
      unitKind: outline.unitKind,
      totalUnits: totalUnits,
      window: selectedWindow,
      windowLabel: selectedWindow != null ? describeWindow(outline.unitKind, selectedWindow) : '全书均匀分布',
      batches: batches,
      passageCount: batches.fold(0, (total, batch) => total + batch.passageCount),
    );
  }

  if (window != null) {
    final start = max(0, min(window.start, max(0, totalUnits - 1)));
    final count = max(1, min(window.count, totalUnits - start));
    return buildPlan(StyleSampleWindow(start: start, count: count));
  }
  if (coveredUntil == null) return buildPlan(null);
  final next = nextSampleWindow(totalUnits: totalUnits, coveredUntil: coveredUntil, random: random);
  if (next == null) {
    throw Exception('已蒸馏到全书末尾（共 $totalUnits $unitName）。如需重新扫描请点击“重新开始”。');
  }
  return buildPlan(next);
}

Future<String> readStyleSourceSample(String sourceId) async {
  final plan = await readStyleSourceAnalysisPlan(sourceId: sourceId);
  return plan.batches
      .map((batch) => batch.text.substring(0, min(batch.text.length, _analysisPassageCharacters + 200)))
      .join('\n\n');
}

Future<void> deleteStyleSource(String sourceId) async {
  final source = await getStyleSource(sourceId);
  if (source == null) throw Exception('参考书不存在');
  await deleteStyleSourceRecord(source.id);
  final originalFile = File(source.fileUri);
  final normalizedFile = await _contentFile(source.id);
  if (await originalFile.exists()) await originalFile.delete();
  if (await normalizedFile.exists()) await normalizedFile.delete();
}