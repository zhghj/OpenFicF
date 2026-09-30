import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models.dart';

/// 内置 Agent/Skill 目录。OpenFicM 在首次启动时从远端拉取，
/// Flutter 版直接随 APK 打包，保证离线可用。
class BuiltinCatalog {
  final List<Map<String, dynamic>> agents;
  final List<Map<String, dynamic>> skills;

  const BuiltinCatalog({required this.agents, required this.skills});
}

class PluginSkillDefinition {
  final String id;
  final String name;
  final String description;
  final String instructions;
  final bool enabled;

  const PluginSkillDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.instructions,
    required this.enabled,
  });
}

class CatalogStore {
  static BuiltinCatalog? _builtin;
  static List<PluginSkillDefinition>? _pluginSkills;

  static Future<BuiltinCatalog> loadBuiltin() async {
    if (_builtin != null) return _builtin!;
    final raw = await rootBundle.loadString('assets/openficm-agent-catalog.json');
    final decoded = json.decode(raw);
    if (decoded is! Map) {
      _builtin = const BuiltinCatalog(agents: [], skills: []);
      return _builtin!;
    }
    final agents = (decoded['agents'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry('$key', value)))
        .toList();
    final skills = (decoded['skills'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry('$key', value)))
        .toList();
    _builtin = BuiltinCatalog(agents: agents, skills: skills);
    return _builtin!;
  }

  static Future<List<PluginSkillDefinition>> loadPluginSkills() async {
    if (_pluginSkills != null) return _pluginSkills!;
    final raw = await rootBundle.loadString('assets/lorn-mobile-catalog.json');
    final decoded = json.decode(raw);
    final skills = <PluginSkillDefinition>[];
    if (decoded is Map && decoded['skills'] is List) {
      for (final item in decoded['skills'] as List) {
        if (item is! Map) continue;
        skills.add(PluginSkillDefinition(
          id: '${item['id']}',
          name: '${item['name']}',
          description: '${item['description']}',
          instructions: '${item['instructions']}',
          enabled: item['enabled'] != false,
        ));
      }
    }
    _pluginSkills = skills;
    return skills;
  }
}

/// Lorn 移动插件技能 ID，与 OpenFicM 保持一致。
const List<String> lornStyleSkillIds = [
  'plugin-lorn-style--distillation',
  'plugin-lorn-style--evolution',
];

bool isLornStyleSkillId(String id) => lornStyleSkillIds.contains(id);

bool shouldAttachLornStyleSkills(String agentId, String agentName, String kind) {
  if (kind == 'primary') return true;
  return RegExp('(narrative-writer|writer|写手|正文)', caseSensitive: false)
      .hasMatch('$agentId $agentName');
}

bool shouldInjectAuthorStyleGuide(String agentId, String agentName, String request) {
  return RegExp('(narrative-writer|writer|写手|正文)', caseSensitive: false)
          .hasMatch('$agentId $agentName') ||
      RegExp('(正文|章节|续写|扩写|改写|重写|润色|写作)').hasMatch(request);
}

// 保留以方便后续按作品/类型扩展。
ProviderType providerTypeFromWire(String value) => ProviderType.fromWire(value);