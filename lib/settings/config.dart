import 'dart:convert';

import '../data/repositories.dart';
import 'builtin_catalog.dart';

enum ToolPermissionMode { allow, ask, deny }

enum AgentKind { primary, subagent }

enum CatalogSource { builtin, custom, plugin, remote }

class IndexSettings {
  final bool enabled;
  final int chunkSize;
  final int chunkOverlap;
  final int retrievalTopK;
  final int rerankTopK;
  final bool rerankEnabled;

  const IndexSettings({
    required this.enabled,
    required this.chunkSize,
    required this.chunkOverlap,
    required this.retrievalTopK,
    required this.rerankTopK,
    required this.rerankEnabled,
  });
}

class AgentRule {
  final String id;
  final String name;
  final String content;
  final bool enabled;

  const AgentRule({
    required this.id,
    required this.name,
    required this.content,
    required this.enabled,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'content': content,
        'enabled': enabled,
      };

  factory AgentRule.fromJson(Map<String, dynamic> json) => AgentRule(
        id: '${json['id']}',
        name: '${json['name']}',
        content: '${json['content']}',
        enabled: json['enabled'] != false,
      );
}

class AgentSkill {
  final String id;
  final String name;
  final String description;
  final String instructions;
  final bool enabled;
  final CatalogSource source;

  const AgentSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.instructions,
    required this.enabled,
    required this.source,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'instructions': instructions,
        'enabled': enabled,
        'source': source.name,
      };

  factory AgentSkill.fromJson(Map<String, dynamic> json) => AgentSkill(
        id: '${json['id']}',
        name: '${json['name']}',
        description: '${json['description']}',
        instructions: '${json['instructions']}',
        enabled: json['enabled'] != false,
        source: _sourceFromWire(json['source']),
      );
}

class AgentDefinition {
  final String id;
  final String name;
  final String description;
  final String systemPrompt;
  final String modelId;
  final bool enabled;
  final AgentKind kind;
  final List<String> skillIds;
  final List<String> toolNames;
  final List<String> delegatableAgentIds;
  final CatalogSource source;

  const AgentDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.systemPrompt,
    required this.modelId,
    required this.enabled,
    required this.kind,
    required this.skillIds,
    required this.toolNames,
    required this.delegatableAgentIds,
    required this.source,
  });

  AgentDefinition copyWith({
    String? modelId,
    bool? enabled,
    List<String>? skillIds,
  }) {
    return AgentDefinition(
      id: id,
      name: name,
      description: description,
      systemPrompt: systemPrompt,
      modelId: modelId ?? this.modelId,
      enabled: enabled ?? this.enabled,
      kind: kind,
      skillIds: skillIds ?? this.skillIds,
      toolNames: toolNames,
      delegatableAgentIds: delegatableAgentIds,
      source: source,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'systemPrompt': systemPrompt,
        'modelId': modelId,
        'enabled': enabled,
        'kind': kind.name,
        'skillIds': skillIds,
        'toolNames': toolNames,
        'delegatableAgentIds': delegatableAgentIds,
        'source': source.name,
      };

  factory AgentDefinition.fromJson(Map<String, dynamic> json) => AgentDefinition(
        id: '${json['id']}',
        name: '${json['name']}',
        description: '${json['description']}',
        systemPrompt: '${json['systemPrompt']}',
        modelId: json['modelId'] is String ? json['modelId'] as String : '',
        enabled: json['enabled'] != false,
        kind: json['kind'] == 'subagent' ? AgentKind.subagent : AgentKind.primary,
        skillIds: _stringList(json['skillIds']),
        toolNames: _stringList(json['toolNames']),
        delegatableAgentIds: _stringList(json['delegatableAgentIds']),
        source: _sourceFromWire(json['source']),
      );
}

CatalogSource _sourceFromWire(Object? value) {
  switch (value) {
    case 'builtin':
      return CatalogSource.builtin;
    case 'plugin':
      return CatalogSource.plugin;
    case 'remote':
      return CatalogSource.remote;
    default:
      return CatalogSource.custom;
  }
}

List<String> _stringList(Object? value) {
  if (value is! List) return [];
  final result = <String>{};
  for (final item in value) {
    if (item is String && item.trim().isNotEmpty) result.add(item);
  }
  return result.toList();
}

class ToolCatalogEntry {
  final String key;
  final String name;
  final bool readonly;

  const ToolCatalogEntry(this.key, this.name, this.readonly);
}

const List<ToolCatalogEntry> toolCatalog = [
  ToolCatalogEntry('list_chapters', '列出章节', true),
  ToolCatalogEntry('read_chapter', '读取章节', true),
  ToolCatalogEntry('search_chapters', '全文搜索章节', true),
  ToolCatalogEntry('search_knowledge', '语义检索项目资料', true),
  ToolCatalogEntry('list_characters', '列出角色', true),
  ToolCatalogEntry('read_character', '读取角色', true),
  ToolCatalogEntry('list_world_entries', '列出世界书条目', true),
  ToolCatalogEntry('read_world_entry', '读取世界书条目', true),
  ToolCatalogEntry('list_notes', '列出笔记', true),
  ToolCatalogEntry('read_note', '读取笔记', true),
  ToolCatalogEntry('write_note', '创建笔记', false),
  ToolCatalogEntry('edit_note', '编辑笔记', false),
  ToolCatalogEntry('move_note', '移动笔记归属', false),
  ToolCatalogEntry('delete_note', '删除笔记', false),
  ToolCatalogEntry('ask_user', '向用户提问', true),
  ToolCatalogEntry('activate_skill', '激活技能', true),
  ToolCatalogEntry('delegate_agent', '委派子智能体', true),
  ToolCatalogEntry('read_author_style_guide', '读取作者文风指南', true),
  ToolCatalogEntry('list_style_sources', '列出参考书', true),
  ToolCatalogEntry('read_style_source_sample', '读取参考书样本', true),
  ToolCatalogEntry('list_style_profiles', '列出文风版本', true),
  ToolCatalogEntry('read_style_profile', '读取文风版本', true),
  ToolCatalogEntry('select_style_profile', '切换创作文风', false),
  ToolCatalogEntry('save_reference_style_profile', '保存参考文风', false),
  ToolCatalogEntry('write_chapter', '创建章节', false),
  ToolCatalogEntry('edit_chapter', '修改章节', false),
  ToolCatalogEntry('create_character', '创建角色', false),
  ToolCatalogEntry('edit_character', '修改角色', false),
  ToolCatalogEntry('delete_character', '删除角色', false),
  ToolCatalogEntry('create_world_entry', '创建世界书条目', false),
  ToolCatalogEntry('edit_world_entry', '修改世界书条目', false),
  ToolCatalogEntry('delete_world_entry', '删除世界书条目', false),
  ToolCatalogEntry('save_author_style_guide', '保存作者文风指南', false),
  ToolCatalogEntry('evolve_author_style', '进化作者文风', false),
  ToolCatalogEntry('list_hooks', '列出伏笔', true),
  ToolCatalogEntry('read_chapter_summaries', '读取章节摘要', true),
  ToolCatalogEntry('read_current_state', '读取当前状态', true),
  ToolCatalogEntry('read_story_controls', '读取创作控制', true),
  ToolCatalogEntry('update_current_focus', '更新当前关注点', false),
  ToolCatalogEntry('update_author_intent', '更新作者意图', false),
  ToolCatalogEntry('list_canon_sources', '列出正典素材', true),
  ToolCatalogEntry('read_canon_entries', '读取正典条目', true),
  ToolCatalogEntry('web_disambiguate', '联网消歧', true),
  ToolCatalogEntry('merge_canon_entries', '合并正典条目', false),
  ToolCatalogEntry('create_volume', '新建卷', false),
  ToolCatalogEntry('rename_volume', '重命名卷', false),
  ToolCatalogEntry('update_world_info', '更新世界书说明', false),
  ToolCatalogEntry('create_canon_entry', '新建正典条目', false),
  ToolCatalogEntry('update_canon_entry', '编辑正典条目', false),
  ToolCatalogEntry('delete_canon_entry', '删除正典条目', false),
  ToolCatalogEntry('apply_canon_entry', '应用正典条目', false),
  ToolCatalogEntry('upsert_hook', '维护伏笔', false),
  ToolCatalogEntry('set_hook_status', '修改伏笔状态', false),
  ToolCatalogEntry('delete_hook', '删除伏笔', false),
  ToolCatalogEntry('upsert_state_fact', '设置世界状态事实', false),
  ToolCatalogEntry('expire_state_fact', '失效世界状态事实', false),
  ToolCatalogEntry('write_chapter_summary', '写入章节摘要', false),
  ToolCatalogEntry('delete_chapter_summary', '删除章节摘要', false),
  ToolCatalogEntry('toggle_style_profile', '启用/停用文风', false),
  ToolCatalogEntry('search_canon_entries', '检索正典条目', true),
  ToolCatalogEntry('distill_canon', '蒸馏正典', false),
  ToolCatalogEntry('web_search', '联网检索', true),
  ToolCatalogEntry('merge_characters', '合并角色卡', false),
  ToolCatalogEntry('link_characters', '建立人物关系', false),
  ToolCatalogEntry('link_character_world', '关联角色与世界书', false),
  ToolCatalogEntry('record_event', '记录事件', false),
];

const IndexSettings defaultIndexSettings = IndexSettings(
  enabled: true,
  chunkSize: 360,
  chunkOverlap: 60,
  retrievalTopK: 8,
  rerankTopK: 5,
  rerankEnabled: true,
);

Future<Object?> _readJson(String key) async {
  final value = await getSetting(key);
  if (value == null || value.isEmpty) return null;
  try {
    return json.decode(value);
  } catch (_) {
    return null;
  }
}

Future<void> _writeJson(String key, Object? value) async {
  await setSetting(key, json.encode(value));
}

int _boundedInteger(Object? value, int fallback, int minimum, int maximum) {
  if (value is int && value >= minimum && value <= maximum) return value;
  return fallback;
}

Future<IndexSettings> getIndexSettings() async {
  final value = await _readJson('index.settings');
  if (value is! Map) return defaultIndexSettings;
  final chunkSize = _boundedInteger(value['chunkSize'], defaultIndexSettings.chunkSize, 120, 440);
  return IndexSettings(
    enabled: value['enabled'] is bool ? value['enabled'] as bool : defaultIndexSettings.enabled,
    chunkSize: chunkSize,
    chunkOverlap: _boundedInteger(value['chunkOverlap'], defaultIndexSettings.chunkOverlap, 0, chunkSize - 1),
    retrievalTopK: _boundedInteger(value['retrievalTopK'], defaultIndexSettings.retrievalTopK, 1, 20),
    rerankTopK: _boundedInteger(value['rerankTopK'], defaultIndexSettings.rerankTopK, 1, 12),
    rerankEnabled: value['rerankEnabled'] is bool
        ? value['rerankEnabled'] as bool
        : defaultIndexSettings.rerankEnabled,
  );
}

Future<void> saveIndexSettings(IndexSettings settings) async {
  if (settings.chunkOverlap >= settings.chunkSize) throw Exception('分块重叠必须小于分块大小');
  final chunkSize = _boundedInteger(settings.chunkSize, defaultIndexSettings.chunkSize, 120, 440);
  final chunkOverlap = _boundedInteger(
    settings.chunkOverlap,
    settings.chunkOverlap < chunkSize ? settings.chunkOverlap : chunkSize - 1,
    0,
    chunkSize - 1,
  );
  await _writeJson('index.settings', {
    'enabled': settings.enabled,
    'chunkSize': chunkSize,
    'chunkOverlap': chunkOverlap,
    'retrievalTopK': _boundedInteger(settings.retrievalTopK, defaultIndexSettings.retrievalTopK, 1, 20),
    'rerankTopK': _boundedInteger(settings.rerankTopK, defaultIndexSettings.rerankTopK, 1, 12),
    'rerankEnabled': settings.rerankEnabled,
  });
}

Future<Map<String, ToolPermissionMode>> getToolPermissions() async {
  final value = await _readJson('agent.toolPermissions');
  final permissions = <String, ToolPermissionMode>{};
  for (final tool in toolCatalog) {
    final mode = value is Map ? value[tool.key] : null;
    permissions[tool.key] = _permissionFromWire(mode) ?? (tool.readonly ? ToolPermissionMode.allow : ToolPermissionMode.ask);
  }
  return permissions;
}

ToolPermissionMode? _permissionFromWire(Object? value) {
  switch (value) {
    case 'allow':
      return ToolPermissionMode.allow;
    case 'ask':
      return ToolPermissionMode.ask;
    case 'deny':
      return ToolPermissionMode.deny;
    default:
      return null;
  }
}

Future<void> saveToolPermissions(Map<String, ToolPermissionMode> permissions) async {
  final normalized = <String, String>{};
  for (final tool in toolCatalog) {
    normalized[tool.key] = (permissions[tool.key] ?? ToolPermissionMode.ask).name;
  }
  await _writeJson('agent.toolPermissions', normalized);
}

List<AgentRule> _parseRules(Object? value) {
  if (value is! List) return [];
  final rules = <AgentRule>[];
  for (final item in value) {
    if (item is! Map) continue;
    if (item['id'] is! String || item['name'] is! String || item['content'] is! String) continue;
    rules.add(AgentRule.fromJson(item.map((key, item) => MapEntry('$key', item))));
  }
  return rules;
}

List<AgentSkill> _parseCustomSkills(Object? value) {
  if (value is! List) return [];
  final skills = <AgentSkill>[];
  for (final item in value) {
    if (item is! Map) continue;
    if (item['id'] is! String ||
        item['name'] is! String ||
        item['description'] is! String ||
        item['instructions'] is! String) {
      continue;
    }
    skills.add(AgentSkill.fromJson(item.map((key, item) => MapEntry('$key', item))));
  }
  return skills;
}

List<AgentDefinition> _parseCustomAgents(Object? value) {
  if (value is! List) return [];
  final agents = <AgentDefinition>[];
  for (final item in value) {
    if (item is! Map) continue;
    if (item['id'] is! String ||
        item['name'] is! String ||
        item['description'] is! String ||
        item['systemPrompt'] is! String) {
      continue;
    }
    agents.add(AgentDefinition.fromJson(item.map((key, item) => MapEntry('$key', item))));
  }
  return agents;
}

Future<List<AgentRule>> getAgentRules() async => _parseRules(await _readJson('agent.rules'));

Future<void> saveAgentRules(List<AgentRule> rules) async {
  await _writeJson('agent.rules', rules.map((rule) => rule.toJson()).toList());
}

Future<List<AgentSkill>> getAgentSkills() async {
  final value = await _readJson('agent.skills');
  final records = value is List ? value.whereType<Map>().toList() : const <Map>[];
  final overrides = <String, Map>{
    for (final item in records)
      if (item['id'] is String) item['id'] as String: item,
  };
  final builtin = await CatalogStore.loadBuiltin();
  final pluginSkills = await CatalogStore.loadPluginSkills();

  final skills = <AgentSkill>[];
  for (final item in builtin.skills) {
    final id = '${item['id']}';
    final override = overrides[id];
    skills.add(AgentSkill(
      id: id,
      name: '${item['name']}',
      description: '${item['description']}',
      instructions: '${item['instructions']}',
      enabled: override?['enabled'] is bool ? override!['enabled'] as bool : item['enabled'] != false,
      source: CatalogSource.builtin,
    ));
  }
  for (final plugin in pluginSkills) {
    final override = overrides[plugin.id];
    skills.add(AgentSkill(
      id: plugin.id,
      name: plugin.name,
      description: plugin.description,
      instructions: plugin.instructions,
      enabled: override?['enabled'] is bool ? override!['enabled'] as bool : plugin.enabled,
      source: CatalogSource.plugin,
    ));
  }
  final managedIds = skills.map((skill) => skill.id).toSet();
  for (final custom in _parseCustomSkills(value)) {
    if (!managedIds.contains(custom.id)) {
      skills.add(AgentSkill(
        id: custom.id,
        name: custom.name,
        description: custom.description,
        instructions: custom.instructions,
        enabled: custom.enabled,
        source: CatalogSource.custom,
      ));
    }
  }
  return skills;
}

Future<void> saveAgentSkills(List<AgentSkill> skills) async {
  final builtin = await CatalogStore.loadBuiltin();
  final pluginSkills = await CatalogStore.loadPluginSkills();
  final managedIds = <String>{
    ...builtin.skills.map((item) => '${item['id']}'),
    ...pluginSkills.map((item) => item.id),
  };
  final payload = skills.map((skill) => managedIds.contains(skill.id)
      ? {'id': skill.id, 'enabled': skill.enabled}
      : skill.toJson()).toList();
  await _writeJson('agent.skills', payload);
}

Future<List<AgentDefinition>> getAgentDefinitions() async {
  final value = await _readJson('agent.definitions');
  final records = value is List ? value.whereType<Map>().toList() : const <Map>[];
  final overrides = <String, Map>{
    for (final item in records)
      if (item['id'] is String) item['id'] as String: item,
  };
  final builtin = await CatalogStore.loadBuiltin();
  final agents = <AgentDefinition>[];
  for (final item in builtin.agents) {
    final id = '${item['id']}';
    final override = overrides[id];
    var agent = AgentDefinition(
      id: id,
      name: '${item['name']}',
      description: '${item['description']}',
      systemPrompt: '${item['systemPrompt']}',
      modelId: item['modelId'] is String ? item['modelId'] as String : '',
      enabled: override?['enabled'] is bool ? override!['enabled'] as bool : item['enabled'] != false,
      kind: item['kind'] == 'subagent' ? AgentKind.subagent : AgentKind.primary,
      skillIds: _stringList(item['skillIds']),
      toolNames: _stringList(item['toolNames']),
      delegatableAgentIds: _stringList(item['delegatableAgentIds']),
      source: CatalogSource.builtin,
    );
    if (override?['modelId'] is String) agent = agent.copyWith(modelId: override!['modelId'] as String);
    if (shouldAttachLornStyleSkills(agent.id, agent.name, agent.kind.name)) {
      agent = agent.copyWith(skillIds: {...agent.skillIds, ...lornStyleSkillIds}.toList());
    }
    agents.add(agent);
  }
  final managedIds = agents.map((agent) => agent.id).toSet();
  for (final custom in _parseCustomAgents(value)) {
    if (!managedIds.contains(custom.id)) agents.add(custom);
  }
  return agents;
}

Future<void> saveAgentDefinitions(List<AgentDefinition> definitions) async {
  final builtin = await CatalogStore.loadBuiltin();
  final managedIds = builtin.agents.map((item) => '${item['id']}').toSet();
  final payload = definitions
      .map((agent) => managedIds.contains(agent.id)
          ? {'id': agent.id, 'enabled': agent.enabled, 'modelId': agent.modelId}
          : agent.toJson())
      .toList();
  await _writeJson('agent.definitions', payload);
}