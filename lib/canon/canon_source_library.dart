import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../canon_models.dart';
import '../core/utils.dart';
import '../data/canon_repositories.dart';
import '../style/source_library.dart';

const String _canonDirectoryName = 'canon-library';

Future<Directory> _canonDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  final directory = Directory(p.join(documents.path, _canonDirectoryName));
  if (!await directory.exists()) await directory.create(recursive: true);
  return directory;
}

Future<File> _contentFile(String sourceId) async {
  final directory = await _canonDirectory();
  return File(p.join(directory.path, '$sourceId.content.txt'));
}

String _extensionOf(String fileName) {
  final match = RegExp(r'\.([^.]+)$').firstMatch(fileName.trim());
  return match?.group(1)?.toLowerCase() ?? '';
}

Future<CanonSource?> importCanonSourceFromBytes({
  required String projectId,
  required Uint8List bytes,
  required String fileName,
}) async {
  final parsed = parseDocumentBytes(bytes: bytes, fileName: fileName);
  final contentHash = sha256.convert(bytes).toString();
  final duplicate = await findCanonSourceByHash(projectId, contentHash);
  if (duplicate != null) throw Exception('《${duplicate.title}》已在本作正典库中');
  if (parsed.text.trim().isEmpty) throw Exception('文件中没有可读取的正文');
  final id = createId();
  final directory = await _canonDirectory();
  final extension = _extensionOf(fileName);
  final originalFile =
      File(p.join(directory.path, '$id${extension.isEmpty ? '' : '.$extension'}'));
  final normalizedFile = File(p.join(directory.path, '$id.content.txt'));
  try {
    await originalFile.writeAsBytes(bytes, flush: true);
    await normalizedFile.writeAsString(parsed.text, flush: true);
    return await createCanonSource(
      id: id,
      projectId: projectId,
      title: parsed.title ?? _sourceTitle(fileName),
      fileName: fileName,
      format: parsed.format,
      fileUri: originalFile.path,
      sizeBytes: bytes.length,
      contentHash: contentHash,
      characterCount: parsed.text.length,
    );
  } catch (error) {
    if (await originalFile.exists()) await originalFile.delete();
    if (await normalizedFile.exists()) await normalizedFile.delete();
    rethrow;
  }
}

String _sourceTitle(String fileName) {
  final stripped = fileName.replaceAll(RegExp(r'\.[^.]+$'), '').trim();
  return stripped.isEmpty ? '未命名正典' : stripped;
}

Future<String> readCanonText(CanonSource source) async {
  final file = await _contentFile(source.id);
  if (!await file.exists()) throw Exception('正典正文文件已丢失，请重新导入');
  return file.readAsString();
}

Future<void> deleteCanonSourceFiles(CanonSource source) async {
  final originalFile = File(source.fileUri);
  final normalizedFile = await _contentFile(source.id);
  if (await originalFile.exists()) await originalFile.delete();
  if (await normalizedFile.exists()) await normalizedFile.delete();
}