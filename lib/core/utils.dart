import 'dart:math';

/// 生成与 OpenFicM 类似的随机 ID。不依赖 uuid 包的格式，本地唯一即可。
String createId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}'
      '-${(8 + (bytes[8] & 0x3)).toRadixString(16)}${hex.substring(17, 20)}'
      '-${hex.substring(20, 32)}';
}

String nowIso() => DateTime.now().toUtc().toIso8601String();

/// 归一化 Base URL：去掉尾部斜杠，校验是 http(s) 地址。
String normalizeBaseUrl(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'/+$'), '');
  final valid = RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(normalized);
  if (!valid) throw Exception('Base URL 必须是 http 或 https 地址');
  return normalized;
}

String requiredText(String value, String label) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw Exception('$label不能为空');
  return normalized;
}

bool isRecord(Object? value) => value is Map && value is! List;

Map<String, dynamic> asRecord(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, item) => MapEntry('$key', item));
  return <String, dynamic>{};
}

/// 把任意错误转成用户可读的字符串，去掉 Dart 的 "Exception: " 前缀。
String errorText(Object error) {
  final raw = error.toString();
  if (raw.startsWith('Exception: ')) return raw.substring(11);
  return raw;
}