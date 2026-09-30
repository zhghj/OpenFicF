import 'dart:async';

import 'package:flutter/material.dart';

import '../data/repositories.dart';
import '../search/indexer.dart';
import '../services/active_model.dart';
import '../services/disambiguation.dart';
import '../settings/config.dart';
import '../tasks/task_pool.dart';
import '../widgets/common.dart';
import 'providers_screen.dart';
import 'task_pool_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _activeModelLabel = '未选择模型';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final label = await getActiveModelLabel();
    if (mounted) setState(() => _activeModelLabel = label);
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _tile(
            icon: Icons.dns_outlined,
            title: '模型与供应商',
            subtitle: 'Base URL、API Key、模型与输出上限',
            onTap: () => _push(const ProvidersScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: const Text('默认模型'),
            subtitle: Text(_activeModelLabel),
          ),
          const Divider(),
          _tile(
            icon: Icons.tune,
            title: '上下文设置',
            subtitle: '历史消息条数、系统提示压缩',
            onTap: () => _push(const _ContextSettingsScreen()),
          ),
          _tile(
            icon: Icons.manage_search,
            title: '索引设置',
            subtitle: '分块大小、检索与重排参数',
            onTap: () => _push(const _IndexSettingsScreen()),
          ),
          _tile(
            icon: Icons.gpp_maybe_outlined,
            title: '工具权限',
            subtitle: '允许 / 每次询问 / 禁止',
            onTap: () => _push(const _ToolPermissionsScreen()),
          ),
          _tile(
            icon: Icons.rule,
            title: '规则',
            subtitle: '始终注入系统提示的写作约束',
            onTap: () => _push(const _RulesScreen()),
          ),
          _tile(
            icon: Icons.auto_awesome_outlined,
            title: '技能',
            subtitle: '按需激活的专业写作指令',
            onTap: () => _push(const _SkillsScreen()),
          ),
          _tile(
            icon: Icons.groups_outlined,
            title: '智能体',
            subtitle: '主智能体与子智能体配置',
            onTap: () => _push(const _AgentsScreen()),
          ),
          const Divider(),
          _tile(
            icon: Icons.travel_explore,
            title: '联网消歧',
            subtitle: '用网络搜索解析同人正典里的实体别名',
            onTap: () => _push(const DisambiguationSettingsScreen()),
          ),
          _tile(
            icon: Icons.task_alt,
            title: '任务池',
            subtitle: '后台长任务（如整部正典蒸馏）与进度',
            onTap: () => _push(const TaskPoolScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.hourglass_top, size: 20),
            title: const Text('进行中的任务'),
            subtitle: ListenableBuilder(
              listenable: TaskPool.instance,
              builder: (context, _) => Text(
                TaskPool.instance.activeCount == 0
                    ? '暂无'
                    : TaskPool.instance.activeTasks.map((task) => task.title).join('、'),
              ),
            ),
          ),
          _tile(
            icon: Icons.cleaning_services_outlined,
            title: '重建本地索引',
            subtitle: '为当前所有作品重建章节/角色/世界书索引',
            onTap: _rebuildIndex,
          ),
          _tile(
            icon: Icons.info_outline,
            title: '关于',
            subtitle: 'OpenFicF · 本地优先的小说创作应用',
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'OpenFicF',
              applicationVersion: '1.0.0',
              applicationLegalese: '参考 OpenFic / OpenFicM 重构，Apache-2.0。',
              children: const [
                SizedBox(height: 12),
                Text('作品、章节、角色、世界书和对话都保存在本机，只有调用你配置的模型 API 时联网。'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Future<void> _rebuildIndex() async {
    try {
      final projects = await listProjects();
      if (!mounted) return;
      showMessageSnack(context, '正在重建 ${projects.length} 个作品的索引…');
      for (final project in projects) {
        await indexProject(project.id, force: true);
      }
      if (mounted) showMessageSnack(context, '索引重建完成');
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }
}

class _ContextSettingsScreen extends StatefulWidget {
  const _ContextSettingsScreen();

  @override
  State<_ContextSettingsScreen> createState() => _ContextSettingsScreenState();
}

class _ContextSettingsScreenState extends State<_ContextSettingsScreen> {
  final _limitController = TextEditingController(text: '30');
  bool _compress = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _limitController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final limit = await getSetting('context.historyLimit');
    final compress = await getSetting('context.compressSystemPrompts');
    if (!mounted) return;
    setState(() {
      _limitController.text = limit ?? '30';
      _compress = compress == 'true';
      _loading = false;
    });
  }

  Future<void> _persist({bool notify = false}) async {
    final limit = int.tryParse(_limitController.text.trim());
    if (limit == null || limit < 4 || limit > 100) {
      if (notify && mounted) showMessageSnack(context, '历史消息条数必须在 4 到 100 之间');
      return;
    }
    await setSettings([
      ('context.historyLimit', '$limit'),
      ('context.compressSystemPrompts', '$_compress'),
    ]);
    if (notify && mounted) showMessageSnack(context, '已保存');
  }

  Future<void> _save() => _persist(notify: true);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('上下文设置')),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _limitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '历史消息条数',
                    helperText: '每次请求携带的最近消息数量（4-100）',
                  ),
                ),
                SwitchListTile(
                  title: const Text('压缩系统提示'),
                  subtitle: const Text('去掉系统提示中的空行，减少上下文占用'),
                  value: _compress,
                  onChanged: (value) async {
                    setState(() => _compress = value);
                    await _persist();
                  },
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _save, child: const Text('保存')),
              ],
            ),
    );
  }
}

class _IndexSettingsScreen extends StatefulWidget {
  const _IndexSettingsScreen();

  @override
  State<_IndexSettingsScreen> createState() => _IndexSettingsScreenState();
}

class _IndexSettingsScreenState extends State<_IndexSettingsScreen> {
  final _chunkSizeController = TextEditingController();
  final _chunkOverlapController = TextEditingController();
  final _retrievalController = TextEditingController();
  final _rerankController = TextEditingController();
  bool _enabled = true;
  bool _rerankEnabled = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _chunkSizeController.dispose();
    _chunkOverlapController.dispose();
    _retrievalController.dispose();
    _rerankController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await getIndexSettings();
    if (!mounted) return;
    setState(() {
      _enabled = settings.enabled;
      _chunkSizeController.text = '${settings.chunkSize}';
      _chunkOverlapController.text = '${settings.chunkOverlap}';
      _retrievalController.text = '${settings.retrievalTopK}';
      _rerankController.text = '${settings.rerankTopK}';
      _rerankEnabled = settings.rerankEnabled;
      _loading = false;
    });
  }

  Future<void> _persist({bool notify = false}) async {
    try {
      await saveIndexSettings(IndexSettings(
        enabled: _enabled,
        chunkSize: int.tryParse(_chunkSizeController.text.trim()) ?? 360,
        chunkOverlap: int.tryParse(_chunkOverlapController.text.trim()) ?? 60,
        retrievalTopK: int.tryParse(_retrievalController.text.trim()) ?? 8,
        rerankTopK: int.tryParse(_rerankController.text.trim()) ?? 5,
        rerankEnabled: _rerankEnabled,
      ));
      if (notify && mounted) showMessageSnack(context, '已保存');
    } catch (error) {
      if (notify && mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _save() => _persist(notify: true);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('索引设置')),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  title: const Text('启用本地索引'),
                  value: _enabled,
                  onChanged: (value) async {
                    setState(() => _enabled = value);
                    await _persist();
                  },
                ),
                TextField(
                  controller: _chunkSizeController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '分块大小（120-440）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _chunkOverlapController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '分块重叠（0 到分块大小-1）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _retrievalController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '召回条数（1-20）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _rerankController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '重排条数（1-12）'),
                ),
                SwitchListTile(
                  title: const Text('启用重排'),
                  value: _rerankEnabled,
                  onChanged: (value) async {
                    setState(() => _rerankEnabled = value);
                    await _persist();
                  },
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _save, child: const Text('保存')),
              ],
            ),
    );
  }
}

class _ToolPermissionsScreen extends StatefulWidget {
  const _ToolPermissionsScreen();

  @override
  State<_ToolPermissionsScreen> createState() => _ToolPermissionsScreenState();
}

class _ToolPermissionsScreenState extends State<_ToolPermissionsScreen> {
  Map<String, ToolPermissionMode> _permissions = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final permissions = await getToolPermissions();
    if (!mounted) return;
    setState(() {
      _permissions = permissions;
      _loading = false;
    });
  }

  Future<void> _set(String key, ToolPermissionMode mode) async {
    setState(() => _permissions = {..._permissions, key: mode});
    await saveToolPermissions(_permissions);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工具权限')),
      body: _loading
          ? const LoadingView()
          : ListView(
              children: [
                for (final tool in toolCatalog)
                  ListTile(
                    title: Text(tool.name),
                    subtitle: Text(tool.key),
                    trailing: DropdownButton<ToolPermissionMode>(
                      value: _permissions[tool.key] ?? ToolPermissionMode.ask,
                      onChanged: (mode) {
                        if (mode != null) _set(tool.key, mode);
                      },
                      items: const [
                        DropdownMenuItem(value: ToolPermissionMode.allow, child: Text('允许')),
                        DropdownMenuItem(value: ToolPermissionMode.ask, child: Text('每次询问')),
                        DropdownMenuItem(value: ToolPermissionMode.deny, child: Text('禁止')),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RulesScreen extends StatefulWidget {
  const _RulesScreen();

  @override
  State<_RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<_RulesScreen> {
  List<AgentRule> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rules = await getAgentRules();
    if (!mounted) return;
    setState(() {
      _rules = rules;
      _loading = false;
    });
  }

  Future<void> _edit([AgentRule? rule]) async {
    final nameController = TextEditingController(text: rule?.name ?? '');
    final contentController = TextEditingController(text: rule?.content ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(rule == null ? '新建规则' : '编辑规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '规则名称')),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 6,
              minLines: 3,
              decoration: const InputDecoration(labelText: '规则内容'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    final next = [..._rules];
    if (rule == null) {
      next.add(AgentRule(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: nameController.text,
          content: contentController.text,
          enabled: true));
    } else {
      final index = next.indexWhere((item) => item.id == rule.id);
      next[index] = AgentRule(
        id: rule.id,
        name: nameController.text,
        content: contentController.text,
        enabled: rule.enabled,
      );
    }
    await saveAgentRules(next);
    await _load();
  }

  Future<void> _toggle(AgentRule rule) async {
    final next = _rules
        .map((item) => item.id == rule.id
            ? AgentRule(id: item.id, name: item.name, content: item.content, enabled: !item.enabled)
            : item)
        .toList();
    await saveAgentRules(next);
    await _load();
  }

  Future<void> _delete(AgentRule rule) async {
    final next = _rules.where((item) => item.id != rule.id).toList();
    await saveAgentRules(next);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('规则'),
        actions: [IconButton(onPressed: () => _edit(), icon: const Icon(Icons.add))],
      ),
      body: _loading
          ? const LoadingView()
          : _rules.isEmpty
              ? EmptyState(
                  icon: Icons.rule,
                  title: '还没有规则',
                  subtitle: '规则会始终注入系统提示，例如“不使用第一人称”。',
                  action: FilledButton.icon(
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('新建规则'),
                  ),
                )
              : ListView(
                  children: [
                    for (final rule in _rules)
                      ListTile(
                        leading: Switch(
                          value: rule.enabled,
                          onChanged: (_) => _toggle(rule),
                        ),
                        title: Text(rule.name),
                        subtitle: Text(rule.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') _edit(rule);
                            if (value == 'delete') _delete(rule);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _SkillsScreen extends StatefulWidget {
  const _SkillsScreen();

  @override
  State<_SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<_SkillsScreen> {
  List<AgentSkill> _skills = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final skills = await getAgentSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _loading = false;
    });
  }

  Future<void> _toggle(AgentSkill skill) async {
    final next = _skills
        .map((item) => item.id == skill.id
            ? AgentSkill(
                id: item.id,
                name: item.name,
                description: item.description,
                instructions: item.instructions,
                enabled: !item.enabled,
                source: item.source,
              )
            : item)
        .toList();
    await saveAgentSkills(next);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('技能')),
      body: _loading
          ? const LoadingView()
          : ListView(
              children: [
                for (final skill in _skills)
                  ListTile(
                    leading: Switch(value: skill.enabled, onChanged: (_) => _toggle(skill)),
                    title: Text(skill.name),
                    subtitle: Text('${skill.source.name} · ${skill.description}',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(skill.name),
                        content: SingleChildScrollView(child: Text(skill.instructions)),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _AgentsScreen extends StatefulWidget {
  const _AgentsScreen();

  @override
  State<_AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<_AgentsScreen> {
  List<AgentDefinition> _agents = [];
  String? _activeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final agents = await getAgentDefinitions();
    final activeId = await getSetting('agent.activeDefinitionId');
    if (!mounted) return;
    setState(() {
      _agents = agents;
      _activeId = activeId;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await saveAgentDefinitions(_agents);
    await _load();
  }

  Future<void> _toggle(AgentDefinition agent) async {
    setState(() {
      _agents = _agents
          .map((item) => item.id == agent.id ? item.copyWith(enabled: !item.enabled) : item)
          .toList();
    });
    await _save();
  }

  Future<void> _setActive(AgentDefinition agent) async {
    await setSetting('agent.activeDefinitionId', agent.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final primaries = _agents.where((agent) => agent.kind == AgentKind.primary).toList();
    final subagents = _agents.where((agent) => agent.kind == AgentKind.subagent).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('智能体')),
      body: _loading
          ? const LoadingView()
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('主智能体'),
                ),
                for (final agent in primaries)
                  _agentTile(agent, isActive: agent.id == _activeId, selectable: true),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('子智能体（由主智能体按任务委派）'),
                ),
                for (final agent in subagents) _agentTile(agent, isActive: false, selectable: false),
              ],
            ),
    );
  }

  Widget _agentTile(AgentDefinition agent, {required bool isActive, required bool selectable}) {
    return ListTile(
      leading: Icon(isActive ? Icons.check_circle : Icons.smart_toy_outlined,
          color: isActive ? Theme.of(context).colorScheme.primary : null),
      title: Text(agent.name),
      subtitle: Text('${agent.description}\n${agent.modelId.isEmpty ? "跟随默认模型" : "指定模型"}',
          maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectable)
            IconButton(
              tooltip: '设为当前主智能体',
              icon: const Icon(Icons.touch_app_outlined),
              onPressed: () => _setActive(agent),
            ),
          Switch(value: agent.enabled, onChanged: (_) => _toggle(agent)),
        ],
      ),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(agent.name),
          content: SingleChildScrollView(child: Text(agent.systemPrompt)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }
}
class DisambiguationSettingsScreen extends StatefulWidget {
  const DisambiguationSettingsScreen({super.key});

  @override
  State<DisambiguationSettingsScreen> createState() => DisambiguationSettingsScreenState();
}

class DisambiguationSettingsScreenState extends State<DisambiguationSettingsScreen> {
  bool _enabled = false;
  DisambiguationProvider _provider = DisambiguationProvider.baiduBaike;
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  String _language = 'zh';
  bool _loading = true;
  bool _testing = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await DisambiguationConfig.load();
    if (!mounted) return;
    setState(() {
      _enabled = config.enabled;
      _provider = config.provider;
      _baseUrlController.text = config.baseUrl;
      _apiKeyController.text = config.apiKey;
      _language = config.language;
      _loading = false;
    });
  }

  /// 立即持久化，切换开关/下拉时自动保存，避免退出后丢失。
  Future<void> _persist() async {
    await DisambiguationConfig.save(DisambiguationConfig(
      enabled: _enabled,
      provider: _provider,
      baseUrl: _baseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      language: _language,
    ));
  }

  void _persistSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _persist);
  }

  Future<void> _save() async {
    _debounce?.cancel();
    await _persist();
    if (mounted) showMessageSnack(context, '已保存');
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      final results = await disambiguate(
        '海格',
        config: DisambiguationConfig(
          enabled: true,
          provider: _provider,
          baseUrl: _baseUrlController.text.trim(),
          apiKey: _apiKeyController.text.trim(),
          language: _language,
        ),
      );
      if (!mounted) return;
      if (results.isEmpty) {
        showMessageSnack(context, '连接成功，但没有返回结果');
      } else {
        showMessageSnack(context, '连接成功，返回 ${results.length} 条（示例：${results.first.title}）');
      }
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final defaultUrl = DisambiguationConfig.defaultBaseUrl(_provider, _language);
    final needsKey = _provider == DisambiguationProvider.serper ||
        _provider == DisambiguationProvider.brave ||
        _provider == DisambiguationProvider.bing ||
        _provider == DisambiguationProvider.bocha;
    return Scaffold(
      appBar: AppBar(title: const Text('联网消歧')),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用联网消歧'),
                  subtitle: const Text('开启后可在正典条目上调用网络搜索解析实体别名'),
                  value: _enabled,
                  onChanged: (value) async {
                    setState(() => _enabled = value);
                    await _persist();
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<DisambiguationProvider>(
                  initialValue: _provider,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '服务商'),
                  items: [
                    for (final provider in DisambiguationProvider.values)
                      DropdownMenuItem(
                        value: provider,
                        child: Text(provider.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) async {
                    setState(() => _provider = value ?? _provider);
                    await _persist();
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _baseUrlController,
                  onChanged: (_) => _persistSoon(),
                  decoration: InputDecoration(
                    labelText: 'Base URL',
                    hintText: defaultUrl.isEmpty ? 'https://your-search.example/api' : defaultUrl,
                    helperText: defaultUrl.isEmpty ? null : '留空使用默认：$defaultUrl',
                  ),
                ),
                if (needsKey) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: true,
                    onChanged: (_) => _persistSoon(),
                    decoration: const InputDecoration(labelText: 'API Key'),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _language,
                  decoration: const InputDecoration(labelText: '检索语言'),
                  items: const [
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                    DropdownMenuItem(value: 'en', child: Text('英文')),
                  ],
                  onChanged: (value) async {
                    setState(() => _language = value ?? 'zh');
                    await _persist();
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testing ? null : _test,
                        icon: _testing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.wifi_tethering),
                        label: const Text('测试连接'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(onPressed: _save, child: const Text('保存')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '中国大陆可用：百度百科（免费、免 Key，适合中文实体）、Bing Web Search、博查 Bocha。'
                  'Wikidata / Wikipedia / Google(Serper) / Brave 在中国大陆通常需要科学上网。'
                  '自定义服务需返回包含 results / data / organic / items / webPages 列表的 JSON。'
                  '联网消歧只发送你提供的实体名称等查询词，不会上传正文。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
