import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/utils.dart';
import '../data/repositories.dart';
import 'secure_store.dart';

/// 联网消歧服务：把别名/代称解析为更规范的实体名称与其它称呼。
/// Wikidata / Wikipedia 免费无需 Key；Serper / Brave 需要 Key；Custom 适配自建 JSON 搜索。

enum DisambiguationProvider {
  baiduBaike('baidu-baike', '百度百科（免费 · 中国大陆可用 · 推荐）'),
  bing('bing', 'Bing Web Search（需 Key · 中国大陆可用）'),
  bocha('bocha', '博查 Bocha（需 Key · 中国大陆 API）'),
  wikidata('wikidata', 'Wikidata（免费 · 中国大陆可能不可达）'),
  wikipedia('wikipedia', 'Wikipedia（免费 · 中国大陆可能不可达）'),
  serper('serper', 'Serper.dev / Google（需 Key · 中国大陆可能不可达）'),
  brave('brave', 'Brave Search（需 Key · 中国大陆可能不可达）'),
  custom('custom', '自定义 JSON 搜索');

  const DisambiguationProvider(this.wire, this.label);
  final String wire;
  final String label;

  static DisambiguationProvider fromWire(String value) {
    // 兼容旧配置：原默认 wikidata 保持不变；新用户默认百度百科。
    return DisambiguationProvider.values
        .firstWhere((provider) => provider.wire == value, orElse: () => DisambiguationProvider.baiduBaike);
  }
}

class DisambiguationResult {
  final String title;
  final String description;
  final String url;
  final List<String> aliases;
  final String source;

  const DisambiguationResult({
    required this.title,
    required this.description,
    required this.url,
    this.aliases = const [],
    required this.source,
  });
}

class DisambiguationConfig {
  final bool enabled;
  final DisambiguationProvider provider;
  final String baseUrl;
  final String apiKey;
  final String language;

  const DisambiguationConfig({
    required this.enabled,
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.language,
  });

  static const _apiKeyRef = 'openfic.disambiguation.apiKey';

  static DisambiguationConfig defaults() => const DisambiguationConfig(
        enabled: false,
        provider: DisambiguationProvider.baiduBaike,
        baseUrl: '',
        apiKey: '',
        language: 'zh',
      );

  static String defaultBaseUrl(DisambiguationProvider provider, String language) {
    switch (provider) {
      case DisambiguationProvider.baiduBaike:
        return 'https://baike.baidu.com';
      case DisambiguationProvider.bing:
        return 'https://api.bing.microsoft.com';
      case DisambiguationProvider.bocha:
        return 'https://api.bochaai.com/v1';
      case DisambiguationProvider.wikidata:
        return 'https://www.wikidata.org';
      case DisambiguationProvider.wikipedia:
        return language == 'en' ? 'https://en.wikipedia.org' : 'https://zh.wikipedia.org';
      case DisambiguationProvider.serper:
        return 'https://google.serper.dev';
      case DisambiguationProvider.brave:
        return 'https://api.search.brave.com';
      case DisambiguationProvider.custom:
        return '';
    }
  }

  static Future<DisambiguationConfig> load() async {
    final enabled = await getSetting('disambiguation.enabled');
    final provider =
        DisambiguationProvider.fromWire(await getSetting('disambiguation.provider') ?? 'baidu-baike');
    final baseUrl = await getSetting('disambiguation.baseUrl') ?? '';
    final language = await getSetting('disambiguation.language') ?? 'zh';
    final apiKey = await SecureStore.read(_apiKeyRef) ?? '';
    return DisambiguationConfig(
      enabled: enabled == 'true',
      provider: provider,
      baseUrl: baseUrl,
      apiKey: apiKey,
      language: language,
    );
  }

  static Future<void> save(DisambiguationConfig config) async {
    await setSettings([
      ('disambiguation.enabled', '${config.enabled}'),
      ('disambiguation.provider', config.provider.wire),
      ('disambiguation.baseUrl', config.baseUrl),
      ('disambiguation.language', config.language),
    ]);
    if (config.apiKey.trim().isEmpty) {
      await SecureStore.delete(_apiKeyRef);
    } else {
      await SecureStore.write(_apiKeyRef, config.apiKey.trim());
    }
  }
}

const int _disambiguationTimeoutMs = 20000;

String _stripHtml(String value) => value.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll('&quot;', '"');

Future<Map<String, dynamic>> _getJson(Uri uri, Map<String, String> headers) async {
  final response = await http.get(uri, headers: headers).timeout(const Duration(milliseconds: _disambiguationTimeoutMs));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('消歧服务返回 HTTP ${response.statusCode}');
  }
  final decoded = json.decode(utf8.decode(response.bodyBytes));
  if (decoded is Map) return decoded.map((key, value) => MapEntry('$key', value));
  throw Exception('消歧服务返回了非对象 JSON');
}

Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, String> headers, Map<String, dynamic> body) async {
  final response = await http
      .post(uri, headers: {...headers, 'Content-Type': 'application/json'}, body: json.encode(body))
      .timeout(const Duration(milliseconds: _disambiguationTimeoutMs));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('消歧服务返回 HTTP ${response.statusCode}');
  }
  final decoded = json.decode(utf8.decode(response.bodyBytes));
  if (decoded is Map) return decoded.map((key, value) => MapEntry('$key', value));
  throw Exception('消歧服务返回了非对象 JSON');
}

/// 联网检索实体，返回候选规范名称、描述、链接与别名。
Future<List<DisambiguationResult>> disambiguate(String query, {DisambiguationConfig? config}) async {
  final normalized = query.trim();
  if (normalized.isEmpty) return [];
  final effective = config ?? await DisambiguationConfig.load();
  if (!effective.enabled) throw Exception('联网消歧未启用，请先在设置中开启');

  final base = effective.baseUrl.trim().isEmpty
      ? DisambiguationConfig.defaultBaseUrl(effective.provider, effective.language)
      : normalizeBaseUrl(effective.baseUrl);

  switch (effective.provider) {
    case DisambiguationProvider.baiduBaike:
      return _baiduBaike(base, normalized);
    case DisambiguationProvider.bing:
      return _bing(base, normalized, effective.apiKey);
    case DisambiguationProvider.bocha:
      return _bocha(base, normalized, effective.apiKey);
    case DisambiguationProvider.wikidata:
      return _wikidata(base, normalized, effective.language);
    case DisambiguationProvider.wikipedia:
      return _wikipedia(base, normalized);
    case DisambiguationProvider.serper:
      return _serper(base, normalized, effective.apiKey);
    case DisambiguationProvider.brave:
      return _brave(base, normalized, effective.apiKey);
    case DisambiguationProvider.custom:
      return _custom(base, normalized, effective.apiKey);
  }
}

/// 从摘要文本中提取“又称/别名/绰号”等称呼。
List<String> _extractAliases(String text) {
  final aliases = <String>{};
  final pattern = RegExp(r'(?:又称|别名|别称|绰号|亦作|又名|通称|昵称|俗称)[：:是为]?\s*([^，。；、！？\n]{1,20})');
  for (final match in pattern.allMatches(text)) {
    final alias = match.group(1)?.trim();
    if (alias != null && alias.isNotEmpty) aliases.add(alias);
  }
  return aliases.toList();
}

Future<List<DisambiguationResult>> _baiduBaike(String base, String query) async {
  final uri = Uri.parse('$base/api/openapi/BaikeLemmaCardApi').replace(queryParameters: {
    'scope': '103',
    'format': 'json',
    'appid': '379020',
    'bk_key': query,
    'bk_length': '600',
  });
  final data = await _getJson(uri, {
    'Accept': 'application/json',
    'Referer': 'https://baike.baidu.com/',
    'User-Agent': 'Mozilla/5.0 (Android) OpenFicF',
  });
  final title = '${data['key'] ?? query}'.trim();
  final abstract = '${data['abstract'] ?? ''}'.trim();
  if (title.isEmpty && abstract.isEmpty) return [];
  return [
    DisambiguationResult(
      title: title.isEmpty ? query : title,
      description: abstract,
      url: '${data['url'] ?? 'https://baike.baidu.com/item/$query'}'.trim(),
      aliases: _extractAliases(abstract),
      source: '百度百科',
    ),
  ];
}

Future<List<DisambiguationResult>> _bing(String base, String query, String apiKey) async {
  if (apiKey.trim().isEmpty) throw Exception('Bing 需要在设置中填写 API Key');
  final uri = Uri.parse('$base/v7.0/search').replace(queryParameters: {
    'q': query,
    'count': '8',
    'mkt': 'zh-CN',
  });
  final data = await _getJson(uri, {
    'Ocp-Apim-Subscription-Key': apiKey,
    'Accept': 'application/json',
  });
  final pages = data['webPages'] is Map ? (data['webPages'] as Map)['value'] : null;
  return _fromOrganic(pages, 'Bing');
}

Future<List<DisambiguationResult>> _bocha(String base, String query, String apiKey) async {
  if (apiKey.trim().isEmpty) throw Exception('博查需要在设置中填写 API Key');
  final data = await _postJson(
    Uri.parse('$base/web-search'),
    {'Authorization': 'Bearer $apiKey', 'Accept': 'application/json'},
    {'query': query, 'count': 8, 'summary': true},
  );
  Object? pages;
  if (data['data'] is Map) {
    pages = (data['data'] as Map)['webPages'];
    if (pages is Map) pages = pages['value'];
  }
  pages ??= data['webPages'] is Map ? (data['webPages'] as Map)['value'] : null;
  return _fromOrganic(pages, '博查');
}

Future<List<DisambiguationResult>> _wikidata(String base, String query, String language) async {
  final lang = language == 'en' ? 'en' : 'zh';
  final uri = Uri.parse('$base/w/api.php').replace(queryParameters: {
    'action': 'wbsearchentities',
    'format': 'json',
    'search': query,
    'language': lang,
    'uselang': lang,
    'limit': '8',
    'origin': '*',
  });
  final data = await _getJson(uri, const {'Accept': 'application/json'});
  final results = <DisambiguationResult>[];
  final search = data['search'];
  if (search is List) {
    for (final item in search.whereType<Map>()) {
      final label = '${item['label'] ?? ''}'.trim();
      if (label.isEmpty) continue;
      final id = '${item['id'] ?? ''}';
      final aliases = (item['aliases'] as List<dynamic>? ?? []).whereType<String>().toList();
      results.add(DisambiguationResult(
        title: label,
        description: '${item['description'] ?? ''}'.trim(),
        url: id.isEmpty ? 'https://www.wikidata.org' : 'https://www.wikidata.org/wiki/$id',
        aliases: aliases,
        source: 'Wikidata',
      ));
    }
  }
  return results;
}

Future<List<DisambiguationResult>> _wikipedia(String base, String query) async {
  final uri = Uri.parse('$base/w/api.php').replace(queryParameters: {
    'action': 'query',
    'format': 'json',
    'list': 'search',
    'srsearch': query,
    'srlimit': '8',
    'origin': '*',
  });
  final data = await _getJson(uri, const {'Accept': 'application/json'});
  final results = <DisambiguationResult>[];
  final search = data['query'] is Map ? (data['query'] as Map)['search'] : null;
  if (search is List) {
    for (final item in search.whereType<Map>()) {
      final title = '${item['title'] ?? ''}'.trim();
      if (title.isEmpty) continue;
      final pageId = item['pageid'];
      results.add(DisambiguationResult(
        title: title,
        description: _stripHtml('${item['snippet'] ?? ''}'),
        url: pageId == null ? base : '$base/?curid=$pageId',
        source: 'Wikipedia',
      ));
    }
  }
  return results;
}

Future<List<DisambiguationResult>> _serper(String base, String query, String apiKey) async {
  if (apiKey.trim().isEmpty) throw Exception('Serper 需要在设置中填写 API Key');
  final data = await _postJson(
    Uri.parse('$base/search'),
    {'X-API-KEY': apiKey},
    {'q': query, 'num': 8},
  );
  return _fromOrganic(data['organic'], 'Serper');
}

Future<List<DisambiguationResult>> _brave(String base, String query, String apiKey) async {
  if (apiKey.trim().isEmpty) throw Exception('Brave 需要在设置中填写 API Key');
  final uri = Uri.parse('$base/res/v1/web/search').replace(queryParameters: {'q': query, 'count': '8'});
  final data = await _getJson(uri, {
    'X-Subscription-Token': apiKey,
    'Accept': 'application/json',
  });
  final web = data['web'] is Map ? (data['web'] as Map)['results'] : null;
  return _fromOrganic(web, 'Brave');
}

List<DisambiguationResult> _fromOrganic(Object? raw, String source) {
  if (raw is! List) return [];
  final results = <DisambiguationResult>[];
  for (final item in raw.whereType<Map>()) {
    final title = '${item['title'] ?? item['name'] ?? ''}'.trim();
    if (title.isEmpty) continue;
    results.add(DisambiguationResult(
      title: title,
      description: '${item['snippet'] ?? item['description'] ?? item['summary'] ?? ''}'.trim(),
      url: '${item['link'] ?? item['url'] ?? ''}'.trim(),
      source: source,
    ));
  }
  return results;
}

Future<List<DisambiguationResult>> _custom(String base, String query, String apiKey) async {
  if (base.isEmpty) throw Exception('自定义搜索需要填写 Base URL');
  final uri = Uri.parse(base).replace(queryParameters: {
    'q': query,
    if (apiKey.trim().isNotEmpty) 'api_key': apiKey,
  });
  final data = await _getJson(uri, const {'Accept': 'application/json'});
  for (final key in ['results', 'data', 'organic', 'items']) {
    final results = _fromOrganic(data[key], 'Custom');
    if (results.isNotEmpty) return results;
  }
  throw Exception('自定义搜索返回的数据中未找到 results/data/organic/items 列表');
}