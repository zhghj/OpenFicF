import 'dart:convert';

import '../canon_models.dart';
import '../core/utils.dart';
import '../data/canon_repositories.dart';
import '../data/note_repositories.dart';
import '../data/project_controls_repositories.dart';
import '../data/repositories.dart';
import '../data/story_state_repositories.dart';
import '../data/style_repositories.dart';
import '../llm/client.dart';
import '../llm/llm_types.dart';
import '../models.dart';
import '../pipeline/prompts.dart';
import '../settings/builtin_catalog.dart';
import '../settings/config.dart';
import '../settings/lorn_style_plugin.dart';
import '../story_models.dart';
import 'tools.dart';

const int maxAgentIterations = 12;
const int maxDelegationDepth = 1;
const int maxTotalModelRequests = 24;
/// 单次对话中助手主动蒸馏正典的次数上限，避免反复请求卡住。
const int maxDistillCanonPerRun = 1;
const int maxTraceStringLength = 700;
const int maxPromptNoteTitles = 40;

const Set<String> characterConsistencyToolNames = {
  'list_characters',
  'read_character',
  'create_character',
  'edit_character',
};

const Set<String> worldConsistencyToolNames = {
  'list_world_entries',
  'read_world_entry',
  'create_world_entry',
  'edit_world_entry',
};

/// 返回 null 表示拒绝；返回（可能是补充过的）参数表示批准。
typedef ToolApproval = Future<Map<String, dynamic>?> Function(
    String name, Map<String, dynamic> args);
typedef AskUser = Future<AgentClarificationResponse> Function(AgentClarificationRequest request);
typedef TraceListener = void Function(AgentRunTrace trace);

class _RuntimeCatalog {
  final List<AgentDefinition> agents;
  final List<AgentRule> rules;
  final List<AgentSkill> skills;
  final Map<String, ToolPermissionMode> permissions;
  final int historyLimit;
  final bool compressSystemPrompts;
  final bool compressHistory;
  bool styleSelectionConfigured;
  StyleProfile? activeStyleProfile;
  List<StyleProfile> activeStyleProfiles;
  List<StyleProfile> availableStyleProfiles;
  final List<Note> notes;
  final StoryState storyState;
  final ProjectControls controls;
  final List<CanonEntry> canonEntries;

  _RuntimeCatalog({
    required this.agents,
    required this.rules,
    required this.skills,
    required this.permissions,
    required this.historyLimit,
    required this.compressSystemPrompts,
    required this.compressHistory,
    required this.styleSelectionConfigured,
    required this.activeStyleProfile,
    required this.activeStyleProfiles,
    required this.availableStyleProfiles,
    required this.notes,
    required this.storyState,
    required this.controls,
    required this.canonEntries,
  });
}

class _TraceEventDraft {
  final String kind;
  final String status;
  final String title;
  final String agentName;
  final String? toolName;
  final String? detail;
  final String? input;

  const _TraceEventDraft({
    required this.kind,
    required this.status,
    required this.title,
    required this.agentName,
    this.toolName,
    this.detail,
    this.input,
  });
}

class _LoopResult {
  final String content;
  final bool consistencyRequired;
  final bool characterConsistencyChecked;
  final bool worldConsistencyChecked;
  final String? consistencyEventId;

  const _LoopResult({
    required this.content,
    required this.consistencyRequired,
    required this.characterConsistencyChecked,
    required this.worldConsistencyChecked,
    required this.consistencyEventId,
  });
}

class _RequestBudget {
  int remaining;
  int distillUsed = 0;
  _RequestBudget(this.remaining);
}

class _LoopInput {
  final Project project;
  final ModelSelection selection;
  final List<AgentMessage> history;
  final _RuntimeCatalog catalog;
  final AgentDefinition agent;
  final String? consistencyReason;
  final String? consistencyEventId;
  final ToolApproval? approveTool;
  final AskUser? askUser;
  final _TraceRecorder recorder;
  final AgentSkill? requiredSkill;
  final String userRequest;
  final int depth;
  final _RequestBudget budget;

  _LoopInput({
    required this.project,
    required this.selection,
    required this.history,
    required this.catalog,
    required this.agent,
    required this.consistencyReason,
    required this.consistencyEventId,
    required this.approveTool,
    required this.askUser,
    required this.recorder,
    required this.requiredSkill,
    required this.userRequest,
    required this.depth,
    required this.budget,
  });
}

class AgentRunResult {
  final String content;
  final AgentRunTrace trace;

  const AgentRunResult({required this.content, required this.trace});
}

class AgentRunError implements Exception {
  final String message;
  final AgentRunTrace trace;

  AgentRunError(this.message, this.trace);

  @override
  String toString() => message;
}

class _TraceRecorder {
  AgentRunTrace _trace;
  final TraceListener? onTrace;

  _TraceRecorder(AgentDefinition agent, bool collaborationSuggested, this.onTrace)
      : _trace = AgentRunTrace(
          id: createId(),
          status: 'running',
          primaryAgentId: agent.id,
          primaryAgentName: agent.name,
          collaborationRequired: collaborationSuggested,
          startedAt: nowIso(),
          events: const [],
        ) {
    _publish();
  }

  void _publish() => onTrace?.call(snapshot());

  String add(_TraceEventDraft draft) {
    final id = createId();
    _trace = AgentRunTrace(
      id: _trace.id,
      status: _trace.status,
      primaryAgentId: _trace.primaryAgentId,
      primaryAgentName: _trace.primaryAgentName,
      collaborationRequired: _trace.collaborationRequired,
      startedAt: _trace.startedAt,
      completedAt: _trace.completedAt,
      events: [
        ..._trace.events,
        AgentTraceEvent(
          id: id,
          kind: draft.kind,
          status: draft.status,
          title: draft.title,
          agentName: draft.agentName,
          toolName: draft.toolName,
          detail: draft.detail,
          input: draft.input,
          startedAt: nowIso(),
        ),
      ],
    );
    _publish();
    return id;
  }

  void update(
    String id, {
    String? status,
    String? title,
    String? detail,
    String? output,
    String? input,
    bool clearCompletedAt = false,
    String? completedAt,
  }) {
    final isTerminal = status == 'completed' || status == 'error';
    final resolvedCompletedAt = clearCompletedAt
        ? null
        : (completedAt ?? (isTerminal ? nowIso() : null));
    _trace = AgentRunTrace(
      id: _trace.id,
      status: _trace.status,
      primaryAgentId: _trace.primaryAgentId,
      primaryAgentName: _trace.primaryAgentName,
      collaborationRequired: _trace.collaborationRequired,
      startedAt: _trace.startedAt,
      completedAt: _trace.completedAt,
      events: _trace.events.map((event) {
        if (event.id != id) return event;
        return AgentTraceEvent(
          id: event.id,
          kind: event.kind,
          status: status ?? event.status,
          title: title ?? event.title,
          agentName: event.agentName,
          toolName: event.toolName,
          detail: detail ?? event.detail,
          input: input ?? event.input,
          output: output ?? event.output,
          startedAt: event.startedAt,
          completedAt: resolvedCompletedAt ?? event.completedAt,
        );
      }).toList(),
    );
    _publish();
  }

  void complete() {
    _trace = AgentRunTrace(
      id: _trace.id,
      status: 'completed',
      primaryAgentId: _trace.primaryAgentId,
      primaryAgentName: _trace.primaryAgentName,
      collaborationRequired: _trace.collaborationRequired,
      startedAt: _trace.startedAt,
      completedAt: nowIso(),
      events: _trace.events,
    );
    _publish();
  }

  void fail(String message) {
    final completedAt = nowIso();
    _trace = AgentRunTrace(
      id: _trace.id,
      status: 'error',
      primaryAgentId: _trace.primaryAgentId,
      primaryAgentName: _trace.primaryAgentName,
      collaborationRequired: _trace.collaborationRequired,
      startedAt: _trace.startedAt,
      completedAt: completedAt,
      events: _trace.events.map((event) {
        if (event.status != 'running' && event.status != 'waiting') return event;
        final detail = event.detail == null ? message : '${event.detail}\n$message';
        return AgentTraceEvent(
          id: event.id,
          kind: event.kind,
          status: 'error',
          title: event.title,
          agentName: event.agentName,
          toolName: event.toolName,
          detail: detail,
          input: event.input,
          output: event.output,
          startedAt: event.startedAt,
          completedAt: completedAt,
        );
      }).toList(),
    );
    _publish();
  }

  AgentRunTrace snapshot() {
    return AgentRunTrace(
      id: _trace.id,
      status: _trace.status,
      primaryAgentId: _trace.primaryAgentId,
      primaryAgentName: _trace.primaryAgentName,
      collaborationRequired: _trace.collaborationRequired,
      startedAt: _trace.startedAt,
      completedAt: _trace.completedAt,
      events: _trace.events
          .map((event) => AgentTraceEvent(
                id: event.id,
                kind: event.kind,
                status: event.status,
                title: event.title,
                agentName: event.agentName,
                toolName: event.toolName,
                detail: event.detail,
                input: event.input,
                output: event.output,
                startedAt: event.startedAt,
                completedAt: event.completedAt,
              ))
          .toList(),
    );
  }
}

String _truncate(String value, [int maximum = maxTraceStringLength]) {
  final normalized = value.trim();
  return normalized.length > maximum ? '${normalized.substring(0, maximum)}…' : normalized;
}

Object? _compactTraceValue(Object? value, [int depth = 0]) {
  if (value is String) return _truncate(value);
  if (value is num || value is bool || value == null) return value;
  if (depth >= 3) return value is List ? '[${value.length} 项]' : '[对象]';
  if (value is List) {
    final items = value.take(8).map((item) => _compactTraceValue(item, depth + 1)).toList();
    if (value.length > items.length) items.add('…另有 ${value.length - items.length} 项');
    return items;
  }
  if (value is Map) {
    final entries = value.entries.take(12);
    final output = <String, Object?>{};
    for (final entry in entries) {
      output['${entry.key}'] = _compactTraceValue(entry.value, depth + 1);
    }
    if (value.length > output.length) output['…'] = '另有 ${value.length - output.length} 项';
    return output;
  }
  return '$value';
}

String? _formatTracePayload(Object? value) {
  final compact = _compactTraceValue(value);
  if (compact == null) return null;
  final output = compact is String ? compact : const JsonEncoder.withIndent('  ').convert(compact);
  return output.trim().isEmpty ? null : output;
}

String _toolDisplayName(String name) {
  for (final tool in toolCatalog) {
    if (tool.key == name) return tool.name;
  }
  return name;
}

String _toolResultDetail(String name, Map<String, dynamic> result) {
  int count(String key) => result[key] is List ? (result[key] as List).length : 0;
  switch (name) {
    case 'list_chapters':
      return '已读取 ${count('chapters')} 个章节';
    case 'list_characters':
      return '已读取 ${count('characters')} 个角色';
    case 'list_world_entries':
      return '已读取 ${count('entries')} 个世界书条目';
    case 'list_notes':
      return '已读取 ${count('notes')} 条笔记';
    case 'list_hooks':
      return '已读取 ${count('hooks')} 个伏笔';
    case 'read_chapter_summaries':
      return '已读取 ${count('summaries')} 条章节摘要';
    case 'read_current_state':
      return '已读取当前世界状态';
    case 'read_story_controls':
      return '已读取创作控制';
    case 'web_disambiguate':
      return '返回 ${count('results')} 条消歧候选';
    case 'merge_canon_entries':
      return result['success'] == true ? '已合并正典条目：${result['title'] ?? ''}' : '合并未完成';
    case 'create_volume':
      return '已新建卷：${result['title'] ?? ''}';
    case 'rename_volume':
      return '已重命名卷：${result['title'] ?? ''}';
    case 'update_world_info':
      return '已更新世界书说明';
    case 'create_canon_entry':
      return '已新建正典条目：${result['title'] ?? ''}';
    case 'update_canon_entry':
      return '已更新正典条目：${result['title'] ?? ''}';
    case 'delete_canon_entry':
      return '已删除正典条目：${result['title'] ?? ''}';
    case 'apply_canon_entry':
      return '已应用正典条目到${result['applied_type'] ?? '资料'}';
    case 'upsert_hook':
      return '已维护伏笔（当前 ${result['total_hooks'] ?? 0} 条）';
    case 'set_hook_status':
      return '已修改伏笔状态';
    case 'delete_hook':
      return '已删除伏笔';
    case 'upsert_state_fact':
      return '已设置世界状态事实';
    case 'expire_state_fact':
      return '已失效世界状态事实';
    case 'write_chapter_summary':
      return '已写入章节摘要（共 ${result['summaries'] ?? 0} 条）';
    case 'delete_chapter_summary':
      return '已删除章节摘要';
    case 'toggle_style_profile':
      return '已更新启用的文风（当前 ${result['active_count'] ?? 0} 份）';
    case 'search_canon_entries':
      return '搜索到 ${count('results')} 条正典条目';
    case 'distill_canon':
      if (result['skipped'] == true) {
        return result['in_task_pool'] == true ? '正典已在任务池蒸馏，跳过' : '正典已蒸馏完成或达上限，跳过';
      }
      return result['complete'] == true
          ? '正典蒸馏完成：新增 ${result['added'] ?? 0}、合并 ${result['merged'] ?? 0}'
          : '已蒸馏 ${result['covered_until'] ?? 0}/${result['chunk_count'] ?? 0} 片，新增 ${result['added'] ?? 0} 条';
    case 'web_search':
      return result['enabled'] == false ? '联网检索未启用' : '返回 ${count('results')} 条联网结果';
    case 'merge_characters':
      return '已合并 ${result['merged_count'] ?? 0} 个角色到：${result['name'] ?? ''}';
    case 'link_characters':
      return '已建立关系：${result['fact'] ?? ''}';
    case 'link_character_world':
      return '已关联：${result['fact'] ?? ''}';
    case 'record_event':
      return '已记录事件：${result['title'] ?? ''}';
    case 'update_current_focus':
      return '已更新当前关注点';
    case 'update_author_intent':
      return '已更新作者长期意图';
    case 'read_note':
      return '已读取笔记：${result['note'] is Map ? (result['note'] as Map)['title'] ?? '' : ''}'.trim();
    case 'search_chapters':
    case 'search_knowledge':
      return '找到 ${count('results')} 条相关内容';
    case 'read_chapter':
      return '已读取章节：${result['chapter'] is Map ? (result['chapter'] as Map)['title'] ?? '' : ''}'.trim();
    case 'read_character':
      return '已读取角色：${result['character'] is Map ? (result['character'] as Map)['name'] ?? '' : ''}'.trim();
    case 'read_world_entry':
      return '已读取世界书：${result['entry'] is Map ? (result['entry'] as Map)['name'] ?? '' : ''}'.trim();
    case 'read_author_style_guide':
      return result['exists'] == true ? '已读取作者文风指南' : '当前作品尚无作者文风指南';
    case 'list_style_sources':
      return '已读取 ${count('sources')} 本参考书';
    case 'list_style_profiles':
      return '已读取 ${count('profiles')} 个文风版本';
    case 'read_style_source_sample':
      return '已读取参考书样本：${result['source'] is Map ? (result['source'] as Map)['title'] ?? '' : ''}'.trim();
    case 'read_style_profile':
      return '已读取文风：${result['profile'] is Map ? (result['profile'] as Map)['name'] ?? '' : ''}'.trim();
    case 'select_style_profile':
      return '已切换创作文风：${result['active_profile_name'] ?? ''}';
    case 'save_reference_style_profile':
      return '已保存参考文风：${result['name'] ?? ''}';
    case 'save_author_style_guide':
      return '已保存作者文风指南';
    case 'evolve_author_style':
      return '已进化并保存作者文风指南';
  }
  if (result['title'] is String) return '已完成：${result['title']}';
  if (result['name'] is String) return '已完成：${result['name']}';
  return result['success'] == true ? '已完成' : '已返回结果';
}

String _latestUserRequest(List<ChatMessage> history) {
  for (final message in history.reversed) {
    if (message.role == 'user') return message.content.trim();
  }
  return '';
}

bool _requiresKnowledgeSynchronization(String content) {
  final hasKnowledgeSubject = RegExp('(创作思路|世界观|世界书|设定|角色|人物|关系|背景|阵营|势力|地点|规则|能力|剧情|情节)').hasMatch(content);
  final hasDecision = RegExp('(我想|我准备|我决定|确定|设定为|改成|改为|调整|新增|加入|删除|取消|更新|同步|补充|以后|接下来|让.+(?:成为|会|要))').hasMatch(content);
  return hasKnowledgeSubject && hasDecision;
}

bool _requiresAgentCollaboration(String content) {
  if (RegExp('(多智能体|子智能体|agent|协作|分工)', caseSensitive: false).hasMatch(content)) return true;
  final hasAction = RegExp('(帮我|请|需要|设计|规划|分析|审查|检查|完善|调整|生成|构建|梳理|推演)').hasMatch(content);
  final dimensions = [
    RegExp('(章节|正文|文风|对话)'),
    RegExp('(剧情|情节|大纲|节奏|伏笔)'),
    RegExp('(角色|人物|关系|弧光)'),
    RegExp('(世界观|世界书|设定|背景|势力)'),
  ].where((pattern) => pattern.hasMatch(content)).length;
  return hasAction && (dimensions >= 2 || (dimensions >= 1 && content.length >= 80));
}

bool _isWritingRequest(String content) {
  return RegExp('(正文|章节|续写|扩写|改写|重写|润色|仿写|写作|写(?:一|这|第|下|后|个).{0,8}章)').hasMatch(content);
}

List<AgentSkill> _enabledSkillsForAgent(_RuntimeCatalog catalog, AgentDefinition agent) {
  final allowedIds = agent.skillIds.toSet();
  return catalog.skills
      .where((skill) => skill.enabled && (allowedIds.isEmpty || allowedIds.contains(skill.id)))
      .toList();
}

List<AgentDefinition> _enabledDelegates(_RuntimeCatalog catalog, AgentDefinition agent) {
  final allowedIds = agent.delegatableAgentIds.toSet();
  return catalog.agents
      .where((candidate) =>
          candidate.enabled &&
          candidate.kind == AgentKind.subagent &&
          allowedIds.contains(candidate.id))
      .toList();
}

AgentSkill? _requiredSkillForRequest(_RuntimeCatalog catalog, AgentDefinition agent, String request) {
  final skills = _enabledSkillsForAgent(catalog, agent);
  final lornSkillId = RegExp('(更新我的文风|保存并进化文风)').hasMatch(request)
      ? 'plugin-lorn-style--evolution'
      : RegExp('(蒸馏文风|分析小说文风|提取文笔\\s*DNA)', caseSensitive: false).hasMatch(request)
          ? 'plugin-lorn-style--distillation'
          : null;
  if (lornSkillId != null) {
    for (final skill in skills) {
      if (skill.id == lornSkillId) return skill;
    }
    return null;
  }
  if (!_requiresAgentCollaboration(request) && !_requiresKnowledgeSynchronization(request)) {
    return null;
  }
  final preferredIds = RegExp('(审查|检查|质量|复盘)').hasMatch(request)
      ? ['builtin-skill--story-quality', 'builtin-skill--reader-contract']
      : RegExp('(角色|人物|对白|对话|关系)').hasMatch(request)
          ? [
              'builtin-skill--character-design',
              'builtin-skill--character-relationship',
              'builtin-skill--dialogue-design',
            ]
          : RegExp('(正文|章节|续写|扩写|改写|润色)').hasMatch(request)
              ? [
                  'builtin-skill--prose-format',
                  'builtin-skill--story-quality',
                  'builtin-skill--deslop-writing',
                ]
              : RegExp('(世界观|世界书|设定|背景|阵营|势力|创作思路)').hasMatch(request)
                  ? ['builtin-skill--story-state-tracking', 'builtin-skill--story-hooks']
                  : ['builtin-skill--story-state-tracking', 'builtin-skill--story-quality'];
  for (final id in preferredIds) {
    for (final skill in skills) {
      if (skill.id == id) return skill;
    }
  }
  return skills.isEmpty ? null : skills.first;
}

List<AgentToolDefinition> _toolsForAgent(AgentDefinition agent) {
  final allowed = (agent.toolNames.isNotEmpty
          ? agent.toolNames
          : agentTools.map((tool) => tool.name).toList())
      .toSet();
  allowed.addAll({
    'ask_user',
    'read_author_style_guide',
    'save_author_style_guide',
    'evolve_author_style',
    'list_style_sources',
    'read_style_source_sample',
    'list_style_profiles',
    'read_style_profile',
    'select_style_profile',
    'toggle_style_profile',
    'save_reference_style_profile',
    'search_canon_entries',
    'distill_canon',
    'web_search',
    'merge_characters',
    'link_characters',
    'link_character_world',
    'record_event',
    'list_hooks',
    'read_chapter_summaries',
    'read_current_state',
    'read_story_controls',
    'update_current_focus',
    'update_author_intent',
    'list_canon_sources',
    'read_canon_entries',
    'web_disambiguate',
    'merge_canon_entries',
    'create_volume',
    'rename_volume',
    'update_world_info',
    'create_canon_entry',
    'update_canon_entry',
    'delete_canon_entry',
    'apply_canon_entry',
    'upsert_hook',
    'set_hook_status',
    'delete_hook',
    'upsert_state_fact',
    'expire_state_fact',
    'write_chapter_summary',
    'delete_chapter_summary',
  });
  if (agent.kind != AgentKind.primary) allowed.remove('delegate_agent');
  return agentTools.where((tool) => allowed.contains(tool.name)).toList();
}

String _systemPrompt({
  required Project project,
  required _RuntimeCatalog catalog,
  required AgentDefinition agent,
  required String? consistencyReason,
  required String userRequest,
}) {
  final sections = <String>[
    '你是 OpenFicF 移动端的 ${agent.name} 智能体。当前作品是《${project.title}》。\n'
        '作品简介：${project.description.isEmpty ? '暂无' : project.description}\n'
        '作品、章节、角色、世界书和聊天记录都保存在本机；只有调用用户配置的模型 API 时联网。\n'
        '必须依据工具读取到的当前作品数据工作，不得把其他作品的信息混入本作品。\n'
        '用户明确给出新的创作决定、角色变化、世界规则或剧情事实时，不要只在聊天中复述：先读取现有角色与世界书，确认属于正式设定后，调用 create/edit 工具同步到作品。若内容仍是脑暴、存在多种解释或是否采用尚不明确，先调用 ask_user 让用户确认，再写入；不得把未确认的备选想法当作正式设定。\n'
        '章节新增或修改后，优先根据当前正文判断角色或世界书是否真的发生变化；发现已确认的新事实时调用对应 create/edit 工具同步。不要为了形式上的检查阻塞当前任务，也不要在没有变化时反复读取全部资料。删除角色或世界书条目只响应用户明确要求。所有写工具仍受用户权限审批。\n'
        '除角色与世界书外，你还可以直接维护更多资料：用 upsert_hook / set_hook_status / delete_hook 维护伏笔池，用 upsert_state_fact / expire_state_fact 维护当前世界状态，用 write_chapter_summary / delete_chapter_summary 维护章节摘要，用 create_canon_entry / update_canon_entry / apply_canon_entry 维护并应用同人正典，用 create_volume / rename_volume 组织卷，用 update_world_info 维护世界书说明。用户用大段描述交代设定时，先读取相关现有资料，再据此逐条落库，不要只回复摘要。\n'
        '资料已足够满足当前任务时就直接创作或给出结果，不要为了“更完整”反复调用读取/检索/蒸馏；单次对话最多主动蒸馏正典 1 次；若正典已在任务池蒸馏，不要重复请求也不要等待，先基于现有资料创作。仅确需外部事实时才用 web_search，且不要反复检索。\n'
        '你还可以整理与关联资料：用 merge_characters 合并重复角色卡；用 link_characters 建立人物关系；用 link_character_world 关联角色与世界书（所属/持有/位于等）；用 record_event 记录事件并可关联参与角色。这些关系/关联会写入当前世界状态并向后续创作暴露，请优先用它们维护一致性。\n'
        '任务存在会显著影响结果的偏好或歧义时，使用 ask_user 提出一至三个互不依赖的问题；简单问题不要反问。\n'
        '技能不能只凭名称假设内容；任务匹配技能说明时，先调用 activate_skill 加载完整指令。工具参数必须严格符合声明。',
  ];
  if (consistencyReason != null) {
    sections.add('检测到需要关注的作品变动：$consistencyReason\n优先根据当前任务判断是否需要同步角色或世界书；确认的新事实应写入对应资料，不要为了形式检查阻塞本轮任务。');
  }
  if (agent.systemPrompt.trim().isNotEmpty) {
    sections.add('当前智能体定义：\n${agent.systemPrompt.trim()}');
  }
  if (catalog.activeStyleProfiles.isNotEmpty &&
      shouldInjectAuthorStyleGuide(agent.id, agent.name, userRequest)) {
    final guides = catalog.activeStyleProfiles.map((profile) {
      final profileType = profile.kind == StyleProfileKind.author ? '作者文风' : '参考小说文风';
      return '【$profileType · ${profile.name} V${profile.version}】\n${_truncate(profile.guide, 8000)}';
    }).join('\n\n');
    sections.add('当前创作启用了 ${catalog.activeStyleProfiles.length} 份文风约束：\n$guides\n\n'
        '生成或修改正文时必须把这些指南作为额外文风约束并尽量协调；它们不能覆盖用户本轮明确要求、事实一致性或安全边界。不得复制参考小说原句或专有表达。');
  }
  final enabledRules = catalog.rules.where((rule) => rule.enabled && rule.content.trim().isNotEmpty).toList();
  if (enabledRules.isNotEmpty) {
    sections.add('必须遵循的规则：\n${enabledRules.map((rule) => '- ${rule.name}：${rule.content.trim()}').join('\n')}');
  }
  if (catalog.notes.isNotEmpty) {
    const scopeLabel = {
      NoteScope.project: '整书',
      NoteScope.volume: '卷',
      NoteScope.chapter: '章',
    };
    final listed = catalog.notes.take(maxPromptNoteTitles).toList();
    final lines = listed.map((note) => '- [${scopeLabel[note.scope]}] ${note.title}（id: ${note.id}）').toList();
    if (catalog.notes.length > listed.length) {
      lines.add('- 另有 ${catalog.notes.length - listed.length} 条，调用 list_notes 查看完整列表');
    }
    sections.add('当前作品的笔记（此处只有标题，需要正文时调用 read_note）：\n${lines.join('\n')}');
  }
  sections.add('大纲、剧情走向、伏笔规划这类尚未在正文中发生的内容属于笔记，用 write_note 保存，不要写进世界书；世界书只放已经成立的设定，混入未发生的计划会让后续创作把它当成既定事实。');

  final controlsBlock = renderControlsBlock(catalog.controls);
  if (controlsBlock.isNotEmpty) {
    sections.add('当前长篇创作控制：\n$controlsBlock');
  }
  if (catalog.storyState.openHooks.isNotEmpty) {
    sections.add('未回收伏笔（只能用这些真实 hook id，不要改名或重复开同一承诺）：\n'
        '${renderOpenHooksBrief(catalog.storyState)}');
  }
  if (catalog.storyState.summaries.isNotEmpty) {
    final recent = catalog.storyState.summaries.length > 5
        ? catalog.storyState.summaries.sublist(catalog.storyState.summaries.length - 5)
        : catalog.storyState.summaries;
    sections.add('最近章节摘要：\n'
        '${recent.map((row) => '- 第 ${row.chapter} 章 ${row.title}：${row.events}').join('\n')}');
  }
  final activeFacts = catalog.storyState.facts.where((fact) => fact.active).toList();
  if (activeFacts.isNotEmpty) {
    sections.add('当前世界状态（已成立的事实）：\n'
        '${activeFacts.take(20).map((fact) => '- ${fact.subject} · ${fact.predicate}：${fact.object}').join('\n')}');
  }
  if (catalog.canonEntries.isNotEmpty) {
    final listed = catalog.canonEntries.take(12).toList();
    sections.add('同人正典（原作权威参考，启用条目共 ${catalog.canonEntries.length} 条）：\n'
        '${listed.map((entry) => '- [${entry.category.label}] ${entry.title}：${_truncate(entry.summary.isEmpty ? entry.detail : entry.summary, 120)}').join('\n')}'
        '${catalog.canonEntries.length > listed.length ? '\n- 另有 ${catalog.canonEntries.length - listed.length} 条，用 read_canon_entries 查看完整条目' : ''}\n'
        '正典是已成立角色、关系、世界规则与时间线的权威依据；原作没有写明的部分保持未知或先询问，不要自行补全。需要细节时用 read_canon_entries 或 search_canon_entries 检索；若正典蒸馏尚未完成而当前任务又需要该部分资料，可调用 distill_canon 分次补充，完成后再次检索。');
  }

  final skills = _enabledSkillsForAgent(catalog, agent);
  if (skills.isNotEmpty) {
    sections.add('可按需激活的技能：\n${skills.map((skill) => '- ${skill.name}（${skill.id}）：${skill.description}').join('\n')}');
  }
  final delegates = _enabledDelegates(catalog, agent);
  if (delegates.isNotEmpty) {
    sections.add('可委派的子智能体：\n${delegates.map((item) => '- ${item.name}（${item.id}）：${item.description}').join('\n')}\n'
        '需要额外专业视角时才调用 delegate_agent，委派任务包含目标、作品上下文、交付物和限制；单轮续写、润色或小改动自己完成即可，不要为了形式分工额外发起请求。主智能体负责整合结果，不能把子智能体原文不加判断地直接转交用户。');
  }
  return sections.join('\n\n');
}

AgentDefinition _activePrimaryAgent(List<AgentDefinition> agents, String? activeAgentId) {
  for (final agent in agents) {
    if (agent.id == activeAgentId && agent.enabled && agent.kind == AgentKind.primary) return agent;
  }
  for (final agent in agents) {
    if (agent.id == 'builtin-agent--build' && agent.enabled) return agent;
  }
  for (final agent in agents) {
    if (agent.enabled && agent.kind == AgentKind.primary) return agent;
  }
  throw Exception('没有可用的主智能体，请在设置中启用一个主智能体');
}

List<StyleProfile> _latestStyleProfiles(List<StyleProfile> profiles) {
  final series = <String>{};
  final result = <StyleProfile>[];
  for (final profile in profiles) {
    if (series.contains(profile.seriesId)) continue;
    series.add(profile.seriesId);
    result.add(profile);
  }
  return result;
}

/// 把超出上下文窗口的较早对话压缩成要点摘要（一次模型调用）。
Future<String> _summarizeHistory(ModelSelection selection, List<AgentMessage> messages) async {
  final text = messages
      .where((message) => message.role != 'tool')
      .map((message) => '${message.role == 'user' ? '用户' : '助手'}：${message.content.trim()}')
      .where((line) => line.isNotEmpty)
      .join('\n');
  if (text.trim().isEmpty) return '';
  final bounded = text.length > 12000 ? text.substring(text.length - 12000) : text;
  final turn = await callModel(
    selection,
    [
      AgentMessage(
        role: 'system',
        content: '把以下较早的创作对话压缩成要点摘要，保留已确定的设定、已做出的决定、待办事项与用户偏好，'
            '丢弃寒暄与重复内容。不要展开，不要评价。只输出中文摘要。',
      ),
      AgentMessage(role: 'user', content: bounded),
    ],
    const [],
  );
  return _truncate(turn.content, 2000);
}

Future<void> _ensureWritingStyleSelection({
  required String projectId,
  required String request,
  required _RuntimeCatalog catalog,
  required AskUser? askUser,
  required _TraceRecorder recorder,
  required String agentName,
}) async {
  if (!_isWritingRequest(request) ||
      catalog.styleSelectionConfigured ||
      catalog.availableStyleProfiles.isEmpty ||
      askUser == null) {
    return;
  }
  final profiles = _latestStyleProfiles(catalog.availableStyleProfiles).take(4).toList();
  final profileByLabel = <String, StyleProfile>{
    for (final profile in profiles) '${profile.name} V${profile.version}': profile,
  };
  final eventId = recorder.add(_TraceEventDraft(
    kind: 'question',
    status: 'waiting',
    title: '选择本次创作文风',
    agentName: agentName,
    detail: '正文生成前确认要注入的文风版本',
  ));
  final response = await askUser(AgentClarificationRequest(
    id: eventId,
    agentName: agentName,
    questions: [
      AgentClarificationQuestion(
        title: '这次正文使用哪种文风？',
        description: '选择后会绑定到本次 AI 原稿，作者修改后可据此进化个人文风。',
        options: [
          for (var index = 0; index < profiles.length; index += 1)
            AgentClarificationOption(
              label: '${profiles[index].name} V${profiles[index].version}${index == 0 ? '（推荐）' : ''}',
              description: profiles[index].kind == StyleProfileKind.author
                  ? '使用当前作品积累的作者文风'
                  : '使用导入参考小说蒸馏出的约束',
            ),
          const AgentClarificationOption(label: '不使用文风', description: '只遵循本轮要求和作品设定'),
        ],
      ),
    ],
  ));
  if (response.cancelled) {
    recorder.update(eventId, status: 'completed', detail: '本次跳过文风选择');
    return;
  }
  final answer = response.answers.isNotEmpty ? response.answers.first.answer.trim() : '';
  StyleProfile? selected;
  if (!RegExp('不使用|不用|none', caseSensitive: false).hasMatch(answer)) {
    final normalizedAnswer = answer.replaceAll(RegExp('（推荐）\$'), '');
    selected = profileByLabel[normalizedAnswer];
    if (selected == null) {
      for (final profile in profiles) {
        if (profile.id == answer || profile.name == answer) {
          selected = profile;
          break;
        }
      }
    }
    if (selected == null) {
      recorder.update(eventId, status: 'error', detail: '未找到选择的文风版本');
      throw Exception('未找到选择的文风版本，请从文风书库重新选择');
    }
  }
  await setActiveStyleProfile(projectId, selected?.id);
  catalog.styleSelectionConfigured = true;
  catalog.activeStyleProfile = selected;
  catalog.activeStyleProfiles = selected == null ? [] : [selected];
  recorder.update(
    eventId,
    status: 'completed',
    detail: selected != null ? '已选择 ${selected.name} V${selected.version}' : '本次不使用文风',
  );
}

Future<Map<String, dynamic>> _authorizeToolCall(
  AgentToolCall call,
  Map<String, ToolPermissionMode> permissions,
  ToolApproval? approveTool,
) async {
  final permission = permissions[call.name] ?? ToolPermissionMode.ask;
  if (permission == ToolPermissionMode.deny) throw Exception('该工具已在设置中禁用');
  if (permission == ToolPermissionMode.allow) return call.arguments;
  final approved = approveTool == null ? null : await approveTool(call.name, call.arguments);
  if (approved == null) throw Exception('用户未批准本次工具调用');
  return approved;
}

Future<ModelSelection> _selectionForAgent(AgentDefinition agent, ModelSelection fallback) async {
  if (agent.modelId.isEmpty || agent.modelId == fallback.model.id) return fallback;
  final models = await listModels();
  final providers = await listProviders();
  LlmModel? model;
  for (final item in models) {
    if (item.id == agent.modelId) {
      model = item;
      break;
    }
  }
  if (model == null) return fallback;
  Provider? provider;
  for (final item in providers) {
    if (item.id == model.providerId) {
      provider = item;
      break;
    }
  }
  if (provider == null) return fallback;
  final apiKey = await getProviderApiKey(provider);
  if (apiKey.isEmpty) return fallback;
  return ModelSelection(provider: provider, model: model, apiKey: apiKey);
}

String _requiredArgument(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! String || value.trim().isEmpty) throw Exception('缺少参数 $key');
  return value.trim();
}

List<AgentClarificationQuestion> _normalizeQuestions(Map<String, dynamic> args) {
  final raw = args['questions'];
  if (raw is! List || raw.isEmpty || raw.length > 3) {
    throw Exception('ask_user 每次必须提供 1 至 3 个互不依赖的问题');
  }
  final questions = <AgentClarificationQuestion>[];
  for (var index = 0; index < raw.length; index += 1) {
    final item = raw[index];
    if (item is! Map) throw Exception('第 ${index + 1} 个问题格式无效');
    final title = item['title'] is String ? _truncate(item['title'] as String, 160) : '';
    if (title.isEmpty) throw Exception('第 ${index + 1} 个问题缺少标题');
    final description = item['description'] is String ? _truncate(item['description'] as String, 500) : null;
    final optionsRaw = item['options'];
    if (optionsRaw is! List || optionsRaw.length > 5) {
      throw Exception('问题“$title”最多提供 5 个选项');
    }
    final seen = <String>{};
    final options = <AgentClarificationOption>[];
    for (final option in optionsRaw) {
      if (option is! Map || option['label'] is! String) continue;
      final label = _truncate(option['label'] as String, 80);
      if (label.isEmpty || seen.contains(label)) continue;
      seen.add(label);
      options.add(AgentClarificationOption(
        label: label,
        description: option['description'] is String
            ? _truncate(option['description'] as String, 240)
            : null,
      ));
    }
    questions.add(AgentClarificationQuestion(
      title: title,
      description: description,
      options: options,
    ));
  }
  return questions;
}

Future<_LoopResult> _runAgentLoop(_LoopInput input) async {
  final prompt = _systemPrompt(
    project: input.project,
    catalog: input.catalog,
    agent: input.agent,
    consistencyReason: input.consistencyReason,
    userRequest: input.userRequest,
  );
  // 历史超出上限时：默认截断；开启上下文压缩则把更早的消息摘要成要点保留。
  final history = input.history.length > input.catalog.historyLimit
      ? input.history.sublist(input.history.length - input.catalog.historyLimit)
      : input.history;
  String? historySummary;
  if (input.catalog.compressHistory && input.history.length > input.catalog.historyLimit) {
    final overflow = input.history.sublist(0, input.history.length - input.catalog.historyLimit);
    try {
      final summary = await _summarizeHistory(input.selection, overflow);
      if (summary.isNotEmpty) historySummary = summary;
    } catch (_) {
      // 压缩失败时退回截断，不阻塞本轮任务。
    }
  }
  final messages = <AgentMessage>[
    AgentMessage(
      role: 'system',
      content: input.catalog.compressSystemPrompts
          ? prompt.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).join('\n')
          : prompt,
    ),
    if (historySummary != null)
      AgentMessage(role: 'system', content: '较早对话摘要（已压缩，仅供参考）：\n$historySummary'),
    ...history,
  ];
  final tools = _toolsForAgent(input.agent);
  final allowedToolNames = tools.map((tool) => tool.name).toSet();
  var consistencyRequired = input.consistencyReason != null;
  var characterConsistencyChecked = false;
  var worldConsistencyChecked = false;
  var consistencyEventId = input.consistencyEventId;

  if (input.requiredSkill != null) {
    final skillEventId = input.recorder.add(_TraceEventDraft(
      kind: 'skill',
      status: 'running',
      title: '正在激活技能：${input.requiredSkill!.name}',
      agentName: input.agent.name,
      toolName: 'activate_skill',
      detail: '根据当前任务自动加载专业指令',
      input: input.requiredSkill!.description,
    ));
    messages.add(AgentMessage(
      role: 'system',
      content: '已激活技能“${input.requiredSkill!.name}”，必须遵循以下完整指令：\n${input.requiredSkill!.instructions}',
    ));
    input.recorder.update(
      skillEventId,
      status: 'completed',
      title: '已激活技能：${input.requiredSkill!.name}',
      detail: input.requiredSkill!.description,
    );
  }

  if (consistencyRequired && consistencyEventId == null) {
    consistencyEventId = input.recorder.add(_TraceEventDraft(
      kind: 'consistency',
      status: 'running',
      title: '核对角色与世界书',
      agentName: input.agent.name,
      detail: input.consistencyReason ?? '正在检查作品设定变化',
    ));
  }

  for (var iteration = 0; iteration < maxAgentIterations; iteration += 1) {
    if (input.budget.remaining <= 0) {
      throw Exception('本次任务的模型请求次数已达上限，请拆分需求后重试');
    }
    input.budget.remaining -= 1;
    final turn = await callModel(input.selection, messages, tools);
    messages.add(AgentMessage(
      role: 'assistant',
      content: turn.content,
      toolCalls: turn.toolCalls,
    ));

    if (turn.toolCalls.isEmpty) {
      if (consistencyRequired && consistencyEventId != null) {
        input.recorder.update(
          consistencyEventId,
          status: 'completed',
          detail: characterConsistencyChecked && worldConsistencyChecked
              ? '已核对角色与世界书，并同步确认的变化'
              : '已完成本轮创作；未发现需要同步的角色或世界书变化',
        );
      }
      return _LoopResult(
        content: turn.content.isNotEmpty ? turn.content : '模型没有返回内容',
        consistencyRequired: consistencyRequired,
        characterConsistencyChecked: characterConsistencyChecked,
        worldConsistencyChecked: worldConsistencyChecked,
        consistencyEventId: consistencyEventId,
      );
    }

    for (final call in turn.toolCalls) {
      final kind = call.name == 'activate_skill'
          ? 'skill'
          : call.name == 'delegate_agent'
              ? 'agent'
              : call.name == 'ask_user'
                  ? 'question'
                  : 'tool';
      final permission = input.catalog.permissions[call.name] ?? ToolPermissionMode.ask;
      final eventId = input.recorder.add(_TraceEventDraft(
        kind: kind,
        status: permission == ToolPermissionMode.ask ? 'waiting' : 'running',
        title: _toolDisplayName(call.name),
        agentName: input.agent.name,
        toolName: call.name,
        detail: permission == ToolPermissionMode.ask ? '等待工具权限' : '正在执行',
        input: _formatTracePayload(call.arguments),
      ));
      try {
        if (!allowedToolNames.contains(call.name)) {
          throw Exception('${input.agent.name} 无权使用工具 ${call.name}');
        }
        final effectiveArgs =
            await _authorizeToolCall(call, input.catalog.permissions, input.approveTool);
        input.recorder.update(
          eventId,
          status: 'running',
          detail: '正在执行',
          input: _formatTracePayload(effectiveArgs),
        );
        Map<String, dynamic> result;
        var eventTitle = _toolDisplayName(call.name);
        String eventDetail;

        if (call.name == 'ask_user') {
          final questions = _normalizeQuestions(effectiveArgs);
          if (input.askUser == null) throw Exception('当前界面无法接收结构化回答');
          input.recorder.update(
            eventId,
            status: 'waiting',
            title: '${input.agent.name} 需要确认',
            detail: '等待回答 ${questions.length} 个问题',
          );
          final response = await input.askUser!(
            AgentClarificationRequest(id: eventId, agentName: input.agent.name, questions: questions),
          );
          result = {
            'cancelled': response.cancelled,
            'answers': response.answers.map((answer) => answer.answer).toList(),
          };
          eventTitle = '${input.agent.name} 的提问';
          eventDetail = response.cancelled ? '用户跳过了本次问题' : '已回答 ${response.answers.length} 个问题';
        } else if (call.name == 'activate_skill') {
          final requested = _requiredArgument(effectiveArgs, 'skill_name');
          AgentSkill? skill;
          for (final item in _enabledSkillsForAgent(input.catalog, input.agent)) {
            if (item.id == requested || item.name == requested) {
              skill = item;
              break;
            }
          }
          if (skill == null) throw Exception('技能不在 ${input.agent.name} 的可用列表中: $requested');
          result = {
            'skill_id': skill.id,
            'skill_name': skill.name,
            'instructions': skill.instructions,
          };
          eventTitle = '已激活技能：${skill.name}';
          eventDetail = skill.description;
        } else if (call.name == 'delegate_agent') {
          if (input.depth >= maxDelegationDepth || input.agent.kind != AgentKind.primary) {
            throw Exception('只有主智能体可以委派一层子智能体');
          }
          final agentId = _requiredArgument(effectiveArgs, 'agent_id');
          AgentDefinition? childAgent;
          for (final item in _enabledDelegates(input.catalog, input.agent)) {
            if (item.id == agentId) {
              childAgent = item;
              break;
            }
          }
          if (childAgent == null) throw Exception('子智能体不在委派白名单中: $agentId');
          final task = _requiredArgument(effectiveArgs, 'task');
          eventTitle = '${childAgent.name} 正在协作';
          input.recorder.update(eventId, title: eventTitle, detail: '正在读取作品并处理任务');
          final childSelection = await _selectionForAgent(childAgent, input.selection);
          final childResult = await _runAgentLoop(_LoopInput(
            project: input.project,
            selection: childSelection,
            history: [AgentMessage(role: 'user', content: task)],
            catalog: input.catalog,
            agent: childAgent,
            consistencyReason: null,
            consistencyEventId: null,
            approveTool: input.approveTool,
            askUser: input.askUser,
            recorder: input.recorder,
            requiredSkill: _requiredSkillForRequest(input.catalog, childAgent, task),
            userRequest: task,
            depth: input.depth + 1,
            budget: input.budget,
          ));
          result = {
            'agent_id': childAgent.id,
            'agent_name': childAgent.name,
            'result': childResult.content,
          };
          eventDetail = '${childAgent.name} 已返回结果';
        } else if (call.name == 'evolve_author_style') {
          final evolved = await evolveAuthorStyle(
            projectId: input.project.id,
            aiDraft: _requiredArgument(effectiveArgs, 'ai_draft'),
            authorRevision: _requiredArgument(effectiveArgs, 'author_revision'),
            selection: input.selection,
          );
          input.catalog.styleSelectionConfigured = true;
          input.catalog.activeStyleProfile = evolved.profile;
          input.catalog.activeStyleProfiles = [evolved.profile];
          input.catalog.availableStyleProfiles = [
            evolved.profile,
            ...input.catalog.availableStyleProfiles.where((profile) => profile.id != evolved.profile.id),
          ];
          result = {
            'success': true,
            'profile_id': evolved.profile.id,
            'version': evolved.profile.version,
            'guide_characters': evolved.guide.length,
          };
          eventDetail = _toolResultDetail(call.name, result);
        } else if (call.name == 'distill_canon' &&
            input.budget.distillUsed >= maxDistillCanonPerRun) {
          // 单次对话最多主动蒸馏一次，避免反复请求把对话卡住。
          result = {
            'skipped': true,
            'limit_reached': true,
            'message': '本次对话已达蒸馏次数上限，请基于现有资料继续创作；如需继续蒸馏，请让用户在任务池中执行。',
          };
          eventDetail = '已达蒸馏次数上限，跳过';
        } else {
          if (call.name == 'distill_canon') input.budget.distillUsed += 1;
          result = await executeAgentTool(input.project.id, call.name, effectiveArgs,
              selection: input.selection);
          eventDetail = _toolResultDetail(call.name, result);
          if (call.name == 'save_author_style_guide' ||
              call.name == 'select_style_profile' ||
              call.name == 'toggle_style_profile') {
            input.catalog.styleSelectionConfigured = true;
            final active = await getActiveStyleProfiles(input.project.id);
            input.catalog.activeStyleProfiles = active;
            input.catalog.activeStyleProfile = active.isEmpty ? null : active.first;
          }
          if (call.name == 'save_reference_style_profile') {
            input.catalog.availableStyleProfiles = await listStyleProfiles(input.project.id);
          }
          if ((call.name == 'write_chapter' || call.name == 'edit_chapter') && input.depth == 0) {
            consistencyRequired = true;
            characterConsistencyChecked = false;
            worldConsistencyChecked = false;
            if (consistencyEventId == null) {
              consistencyEventId = input.recorder.add(_TraceEventDraft(
                kind: 'consistency',
                status: 'running',
                title: '核对角色与世界书',
                agentName: input.agent.name,
                detail: '章节内容已变化，正在检查关联设定',
              ));
            } else {
              input.recorder.update(
                consistencyEventId,
                status: 'running',
                clearCompletedAt: true,
                detail: '章节内容已变化，正在重新检查关联设定',
              );
            }
          } else if (consistencyRequired) {
            if (characterConsistencyToolNames.contains(call.name)) characterConsistencyChecked = true;
            if (worldConsistencyToolNames.contains(call.name)) worldConsistencyChecked = true;
            if (characterConsistencyChecked && worldConsistencyChecked && consistencyEventId != null) {
              input.recorder.update(
                consistencyEventId,
                status: 'completed',
                detail: '角色与世界书均已完成核对',
              );
            }
          }
        }
        input.recorder.update(
          eventId,
          status: 'completed',
          title: eventTitle,
          detail: eventDetail,
          output: call.name == 'activate_skill' ? null : _formatTracePayload(result),
        );
        messages.add(AgentMessage(
          role: 'tool',
          content: jsonEncode(result),
          toolCallId: call.id,
          toolName: call.name,
        ));
      } catch (error) {
        final message = errorText(error);
        input.recorder.update(eventId, status: 'error', detail: message);
        messages.add(AgentMessage(
          role: 'tool',
          content: jsonEncode({'error': message}),
          toolCallId: call.id,
          toolName: call.name,
        ));
      }
    }
  }
  throw Exception('${input.agent.name} 工具调用次数过多，已停止本次任务');
}

Future<AgentRunResult> runAgent({
  required Project project,
  required ModelSelection selection,
  required List<ChatMessage> history,
  String? agentId,
  ToolApproval? approveTool,
  AskUser? askUser,
  TraceListener? onTrace,
}) async {
  final consistencyKey = 'agent.pendingConsistency.${project.id}';
  final results = await Future.wait<Object?>([
    getAgentRules(),
    getAgentSkills(),
    getAgentDefinitions(),
    getToolPermissions(),
    getSetting('agent.activeDefinitionId'),
    getSetting('context.historyLimit'),
    getSetting('context.compressSystemPrompts'),
    getSetting(consistencyKey),
    getActiveStyleProfiles(project.id),
    listStyleProfiles(project.id),
    listNotes(project.id),
    getStoryState(project.id),
    getProjectControls(project.id),
    listCanonEntries(project.id, enabledOnly: true),
    isStyleSelectionConfigured(project.id),
    getSetting('context.compressHistory'),
  ]);
  final rules = results[0] as List<AgentRule>;
  final skills = results[1] as List<AgentSkill>;
  final agents = results[2] as List<AgentDefinition>;
  final permissions = results[3] as Map<String, ToolPermissionMode>;
  final activeAgentId = results[4] as String?;
  final historyLimitValue = results[5] as String?;
  final compressValue = results[6] as String?;
  final pendingConsistency = results[7] as String?;
  final activeStyleProfiles = results[8] as List<StyleProfile>;
  final availableStyleProfiles = results[9] as List<StyleProfile>;
  final notes = results[10] as List<Note>;
  final storyState = results[11] as StoryState;
  final controls = results[12] as ProjectControls;
  final canonEntries = results[13] as List<CanonEntry>;
  final styleConfigured = results[14] as bool;
  final compressHistoryValue = results[15] as String?;

  final parsedHistoryLimit = int.tryParse(historyLimitValue ?? '');
  final catalog = _RuntimeCatalog(
    rules: rules,
    skills: skills,
    agents: agents,
    permissions: permissions,
    historyLimit: (parsedHistoryLimit != null && parsedHistoryLimit >= 4 && parsedHistoryLimit <= 100)
        ? parsedHistoryLimit
        : 30,
    compressSystemPrompts: compressValue == 'true',
    compressHistory: compressHistoryValue == 'true',
    styleSelectionConfigured: styleConfigured,
    activeStyleProfile: activeStyleProfiles.isEmpty ? null : activeStyleProfiles.first,
    activeStyleProfiles: activeStyleProfiles,
    availableStyleProfiles: availableStyleProfiles,
    notes: notes,
    storyState: storyState,
    controls: controls,
    canonEntries: canonEntries,
  );
  final agent = _activePrimaryAgent(agents, agentId ?? activeAgentId);
  final userRequest = _latestUserRequest(history);
  final delegates = _enabledDelegates(catalog, agent);
  final collaborationSuggested = _requiresAgentCollaboration(userRequest) &&
      delegates.isNotEmpty &&
      _toolsForAgent(agent).any((tool) => tool.name == 'delegate_agent') &&
      permissions['delegate_agent'] != ToolPermissionMode.deny;
  final consistencyReason = (pendingConsistency != null && pendingConsistency.isNotEmpty)
      ? pendingConsistency
      : (_requiresKnowledgeSynchronization(userRequest)
          ? '用户本轮提供了可能影响角色或世界书的创作决定'
          : null);
  final requiredSkill = _requiredSkillForRequest(catalog, agent, userRequest);
  final recorder = _TraceRecorder(agent, collaborationSuggested, onTrace);

  try {
    await _ensureWritingStyleSelection(
      projectId: project.id,
      request: userRequest,
      catalog: catalog,
      askUser: askUser,
      recorder: recorder,
      agentName: agent.name,
    );
    final result = await _runAgentLoop(_LoopInput(
      project: project,
      selection: selection,
      history: history.map((message) => AgentMessage(role: message.role, content: message.content)).toList(),
      catalog: catalog,
      agent: agent,
      consistencyReason: consistencyReason,
      consistencyEventId: null,
      approveTool: approveTool,
      askUser: askUser,
      recorder: recorder,
      requiredSkill: requiredSkill,
      userRequest: userRequest,
      depth: 0,
      budget: _RequestBudget(maxTotalModelRequests),
    ));
    if (result.consistencyRequired) {
      await setSetting(consistencyKey, '');
    }
    recorder.complete();
    return AgentRunResult(content: result.content, trace: recorder.snapshot());
  } catch (error) {
    final message = errorText(error);
    recorder.fail(message);
    throw AgentRunError(message, recorder.snapshot());
  }
}