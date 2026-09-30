import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/utils.dart';
import '../models.dart';

class RemoteModel {
  final String id;
  final String name;

  const RemoteModel({required this.id, required this.name});
}

const int _modelListTimeoutMs = 30000;

Future<Map<String, dynamic>> _fetchJson(String url, Map<String, String> headers) async {
  try {
    final response = await http
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(milliseconds: _modelListTimeoutMs));
    final text = response.body;
    Object? data = <String, dynamic>{};
    try {
      data = text.isEmpty ? <String, dynamic>{} : json.decode(text);
    } catch (_) {
      throw Exception('供应商返回了无法解析的模型列表');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final record = asRecord(data);
      final detail = record['error'] is Map
          ? asRecord(record['error'])['message']
          : record['message'];
      throw Exception('${response.statusCode}: ${detail ?? response.reasonPhrase ?? ''}');
    }
    if (data is! Map) throw Exception('供应商返回的模型列表格式无效');
    return data.map((key, item) => MapEntry('$key', item));
  } on http.ClientException {
    throw Exception('无法连接供应商，请检查网络、Base URL 和证书');
  }
}

List<RemoteModel> _uniqueModels(List<RemoteModel> models) {
  final unique = <String, RemoteModel>{};
  for (final model in models) {
    if (model.id.trim().isNotEmpty) unique[model.id] = model;
  }
  final list = unique.values.toList();
  list.sort((left, right) => left.name.toLowerCase().compareTo(right.name.toLowerCase()));
  return list;
}

Future<List<RemoteModel>> fetchProviderModels(Provider provider, String apiKey) async {
  if (apiKey.trim().isEmpty) throw Exception('供应商没有可用的 API Key');
  final baseUrl = normalizeBaseUrl(provider.baseUrl);
  if (provider.type == ProviderType.googleGenai) {
    final data = await _fetchJson('$baseUrl/models?pageSize=1000', {'x-goog-api-key': apiKey});
    final models = data['models'] is List ? data['models'] as List : <dynamic>[];
    return _uniqueModels([
      for (final item in models)
        if (item is Map && item['name'] is String)
          if ((item['supportedGenerationMethods'] is List
                  ? item['supportedGenerationMethods'] as List
                  : const [])
              .contains('generateContent'))
            RemoteModel(
              id: (item['name'] as String).replaceFirst(RegExp('^models/'), ''),
              name: item['displayName'] is String
                  ? item['displayName'] as String
                  : (item['name'] as String),
            ),
    ]);
  }
  if (provider.type == ProviderType.anthropic) {
    final data = await _fetchJson('$baseUrl/models?limit=1000', {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    });
    final models = data['data'] is List ? data['data'] as List : <dynamic>[];
    return _uniqueModels([
      for (final item in models)
        if (item is Map && item['id'] is String)
          RemoteModel(
            id: item['id'] as String,
            name: item['display_name'] is String ? item['display_name'] as String : item['id'] as String,
          ),
    ]);
  }
  final data = await _fetchJson('$baseUrl/models', {'Authorization': 'Bearer $apiKey'});
  final models = data['data'] is List ? data['data'] as List : <dynamic>[];
  return _uniqueModels([
    for (final item in models)
      if (item is Map && item['id'] is String)
        RemoteModel(
          id: item['id'] as String,
          name: item['name'] is String ? item['name'] as String : item['id'] as String,
        ),
  ]);
}