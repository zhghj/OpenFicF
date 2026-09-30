import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../canon/canon_apply.dart';
import '../canon/canon_source_library.dart';
import '../canon_models.dart';
import '../data/canon_repositories.dart';
import '../models.dart';
import '../pipeline/canon_distiller.dart';
import '../services/active_model.dart';
import '../services/disambiguation.dart';
import '../tasks/canon_tasks.dart';
import '../widgets/common.dart';
import 'settings_screen.dart';
import 'task_pool_screen.dart';

class CanonScreen extends StatefulWidget {
  final Project project;

  const CanonScreen({super.key, required this.project});

  @override
  State<CanonScreen> createState() => _CanonScreenState();
}

class _CanonScreenState extends State<CanonScreen> {
  List<CanonSource> _sources = [];
  List<CanonEntry> _entries = [];
  String? _selectedSourceId;
  bool _loading = true;
  final Set<CanonCategory> _collapsedCategories = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sources = await listCanonSources(widget.project.id);
      final entries = await listCanonEntries(widget.project.id);
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _entries = entries;
        if (_selectedSourceId == null || !sources.any((s) => s.id == _selectedSourceId)) {
          _selectedSourceId = sources.isEmpty ? null : sources.first.id;
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  Future<void> _import() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'md', 'markdown', 'epub'],
      );
      if (files.isEmpty) return;
      final file = files.first;
      final Uint8List bytes = await file.readAsBytes();
      if (!mounted) return;
      showMessageSnack(context, '正在导入并解析正典…');
      final source = await importCanonSourceFromBytes(
        projectId: widget.project.id,
        bytes: bytes,
        fileName: file.name,
      );
      await _load();
      if (mounted && source != null) {
        setState(() => _selectedSourceId = source.id);
        showMessageSnack(context, '导入完成，可开始分片蒸馏');
      }
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  /// 把整部正典蒸馏加入全局任务池；立即返回，不阻塞界面。
  Future<void> _enqueueDistill(CanonSource source, {bool restart = false}) async {
    final selection = await getActiveModelSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    if (restart) {
      final confirmed = await confirmDialog(
        context,
        title: '重新蒸馏整部',
        message: '将删除《${source.title}》已蒸馏的全部正典条目并从头开始，确定继续吗？',
        confirmLabel: '重新开始',
        destructive: true,
      );
      if (!confirmed) return;
      await deleteCanonEntriesForSource(source.id);
      await updateCanonSourceProgress(source.id, coveredUntil: 0, chunkCount: source.chunkCount);
      if (!mounted) return;
      source = source.copyWith(coveredUntil: 0);
    }
    enqueueCanonDistillation(source: source, selection: selection);
    await _load();
    if (mounted) {
      showMessageSnack(context, '已加入任务池，可继续使用其它功能；在「任务池」查看进度、暂停或继续');
    }
  }

  Future<void> _deleteSource(CanonSource source) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除正典',
      message: '确定删除《${source.title}》及其全部蒸馏条目吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteCanonSource(source.id);
      await deleteCanonSourceFiles(source);
      if (_selectedSourceId == source.id) _selectedSourceId = null;
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _editEntry(CanonEntry entry) async {
    final titleController = TextEditingController(text: entry.title);
    final summaryController = TextEditingController(text: entry.summary);
    final detailController = TextEditingController(text: entry.detail);
    final evidenceController = TextEditingController(text: entry.evidence);
    final aliasesController = TextEditingController(text: entry.aliases.join('、'));
    var category = entry.category;
    var enabled = entry.isEnabled;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑正典条目'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<CanonCategory>(
                  isExpanded: true,
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '分类'),
                  items: [
                    for (final item in CanonCategory.values)
                      DropdownMenuItem(value: item, child: Text(item.label)),
                  ],
                  onChanged: (value) => setDialogState(() => category = value ?? category),
                ),
                const SizedBox(height: 12),
                TextField(controller: titleController, decoration: const InputDecoration(labelText: '标题（正式名）')),
                const SizedBox(height: 12),
                TextField(
                  controller: aliasesController,
                  decoration: const InputDecoration(
                    labelText: '别名 / 其它称呼（用、或逗号分隔）',
                    hintText: '例如：德思礼、达力·德思礼',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: summaryController,
                  decoration: const InputDecoration(labelText: '一句话摘要'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: detailController,
                  maxLines: 8,
                  minLines: 4,
                  decoration: const InputDecoration(labelText: '详细内容', alignLabelWithHint: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: evidenceController,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(labelText: '原文依据（短句）', alignLabelWithHint: true),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用（供 Agent 与创作参考）'),
                  value: enabled,
                  onChanged: (value) => setDialogState(() => enabled = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      await updateCanonEntry(
        entry.id,
        category: category,
        title: titleController.text,
        summary: summaryController.text,
        detail: detailController.text,
        evidence: evidenceController.text,
        aliases: aliasesController.text
            .split(RegExp(r'[、,，\n]'))
            .map((alias) => alias.trim())
            .where((alias) => alias.isNotEmpty)
            .toList(),
        isEnabled: enabled,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _mergeEntry(CanonEntry entry) async {
    final candidates =
        _entries.where((item) => item.category == entry.category && item.id != entry.id).toList();
    if (candidates.isEmpty) {
      showMessageSnack(context, '同分类下没有可合并的其它条目');
      return;
    }
    final targetId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('把《${entry.title}》合并到…'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final candidate in candidates)
                ListTile(
                  title: Text(candidate.title),
                  subtitle: Text(
                    candidate.aliases.isEmpty ? candidate.summary : '别名：${candidate.aliases.join('、')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, candidate.id),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
      ),
    );
    if (targetId == null) return;
    try {
      await mergeCanonEntries(targetId: targetId, sourceIds: [entry.id]);
      await _load();
      if (!mounted) return;
      final refine = await confirmDialog(
        context,
        title: 'AI 归并',
        message: '已合并。是否用 AI 把这张复合条目重新整理为一份无重复、无矛盾的新条目？',
        confirmLabel: 'AI 归并',
      );
      if (!refine || !mounted) return;
      CanonEntry? target;
      for (final item in _entries) {
        if (item.id == targetId) target = item;
      }
      if (target != null) await _refineEntry(target);
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _refineEntry(CanonEntry entry) async {
    final selection = await getActiveModelSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    showMessageSnack(context, '正在用 AI 归并…');
    try {
      await refineCanonEntryWithAI(entry: entry, selection: selection);
      await _load();
      if (mounted) showMessageSnack(context, '已生成复合条目');
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _disambiguateEntry(CanonEntry entry) async {
    final config = await DisambiguationConfig.load();
    if (!mounted) return;
    if (!config.enabled) {
      final go = await confirmDialog(
        context,
        title: '联网消歧未启用',
        message: '需要先在设置中开启并配置消歧服务（Wikidata / Wikipedia 免费）。是否前往设置？',
        confirmLabel: '前往设置',
      );
      if (go && mounted) {
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const DisambiguationSettingsScreen()));
      }
      return;
    }
    showMessageSnack(context, '正在联网检索《${entry.title}》…');
    try {
      final results = await disambiguate(entry.title, config: config);
      if (!mounted) return;
      if (results.isEmpty) {
        showMessageSnack(context, '没有找到候选实体');
        return;
      }
      final selected = await showModalBottomSheet<DisambiguationResult>(
        context: context,
        showDragHandle: true,
        builder: (context) => ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('选择规范实体', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final result in results)
              ListTile(
                title: Text(result.title),
                subtitle: Text(
                  '${result.source}${result.description.isEmpty ? '' : ' · ${result.description}'}'
                  '${result.aliases.isEmpty ? '' : '\n别名：${result.aliases.join('、')}'}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, result),
              ),
          ],
        ),
      );
      if (selected == null) return;
      final aliases = <String>{...entry.aliases, entry.title, ...selected.aliases}
        ..removeWhere((alias) => alias.trim().toLowerCase() == selected.title.trim().toLowerCase())
        ..removeWhere((alias) => alias.trim().isEmpty);
      await updateCanonEntry(
        entry.id,
        title: selected.title,
        aliases: aliases.toList(),
        evidence: entry.evidence.trim().isEmpty
            ? '联网参考：${selected.source} · ${selected.title}'
            : entry.evidence,
      );
      await _load();
      if (!mounted) return;
      final refine = await confirmDialog(
        context,
        title: 'AI 归并',
        message: '已按“${selected.title}”更新名称与别名，是否用 AI 重新整理这张卡片？',
        confirmLabel: 'AI 归并',
      );
      if (!refine || !mounted) return;
      CanonEntry? updated;
      for (final item in _entries) {
        if (item.id == entry.id) updated = item;
      }
      if (updated != null) await _refineEntry(updated);
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _toggleEntry(CanonEntry entry) async {
    await updateCanonEntry(entry.id, isEnabled: !entry.isEnabled);
    await _load();
  }

  Future<void> _deleteEntry(CanonEntry entry) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除条目',
      message: '确定删除《${entry.title}》吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    await deleteCanonEntry(entry.id);
    await _load();
  }

  Future<void> _applyEntry(CanonEntry entry) async {
    try {
      final result = await applyCanonEntry(projectId: widget.project.id, entry: entry);
      if (mounted) showMessageSnack(context, '已写入${_appliedLabel(result.appliedType)}');
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  List<CanonEntry> get _visibleEntries =>
      _entries.where((entry) => entry.sourceId == _selectedSourceId).toList();

  @override
  Widget build(BuildContext context) {
    final visible = _visibleEntries;
    final byCategory = <CanonCategory, List<CanonEntry>>{};
    for (final entry in visible) {
      byCategory.putIfAbsent(entry.category, () => []).add(entry);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('同人正典'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: '刷新进度'),
          const TaskPoolButton(),
          IconButton(onPressed: _import, icon: const Icon(Icons.add), tooltip: '导入原作'),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('原作素材', style: Theme.of(context).textTheme.titleMedium),
                    ),
                    TextButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('导入 TXT / MD / EPUB'),
                    ),
                  ],
                ),
                if (_sources.isEmpty)
                  const Card(
                    child: ListTile(
                      title: Text('还没有正典素材'),
                      subtitle: Text('导入同人原作后，可分片蒸馏出时间线、角色卡、世界观与人物关系，供其它资料引用。'),
                    ),
                  ),
                for (final source in _sources)
                  Card(
                    color: source.id == _selectedSourceId
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                    child: ListTile(
                      leading: const Icon(Icons.library_books_outlined),
                      title: Text(source.title),
                      subtitle: Text(
                        '${source.format.toUpperCase()} · ${source.characterCount} 字 · '
                        '蒸馏进度 ${source.coveredUntil}/${source.chunkCount} 片'
                        '${source.complete ? '（已完成）' : ''}',
                      ),
                      isThreeLine: true,
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'distill') _enqueueDistill(source);
                          if (value == 'restart') _enqueueDistill(source, restart: true);
                          if (value == 'delete') _deleteSource(source);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'distill',
                            child: Text(source.complete ? '整部再蒸馏一轮' : '蒸馏整部（加入任务池）'),
                          ),
                          const PopupMenuItem(value: 'restart', child: Text('重新蒸馏整部')),
                          const PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () => setState(() => _selectedSourceId = source.id),
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text('正典条目（${visible.length}）',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    if (byCategory.isNotEmpty)
                      IconButton(
                        tooltip: _collapsedCategories.isEmpty ? '全部收起' : '全部展开',
                        onPressed: () => setState(() {
                          if (_collapsedCategories.isEmpty) {
                            _collapsedCategories.addAll(byCategory.keys);
                          } else {
                            _collapsedCategories.clear();
                          }
                        }),
                        icon: Icon(
                          _collapsedCategories.isEmpty ? Icons.unfold_less : Icons.unfold_more,
                        ),
                      ),
                    if (_selectedSourceId != null)
                      TextButton.icon(
                        onPressed: () {
                          final source = _sources.where((s) => s.id == _selectedSourceId).firstOrNull;
                          if (source != null) _enqueueDistill(source);
                        },
                        icon: const Icon(Icons.playlist_add_check),
                        label: const Text('蒸馏整部'),
                      ),
                  ],
                ),
                if (visible.isEmpty)
                  const Card(
                    child: ListTile(
                      title: Text('暂无正典条目'),
                      subtitle: Text('点击“蒸馏整部（加入任务池）”，后台对整部原作分片蒸馏，不阻塞其它操作。'),
                    ),
                  ),
                for (final category in CanonCategory.values)
                  if (byCategory[category]?.isNotEmpty ?? false) ...[
                    _categoryHeader(category, byCategory[category]!.length),
                    if (!_collapsedCategories.contains(category))
                      for (final entry in byCategory[category]!) _entryTile(entry),
                  ],
              ],
            ),
    );
  }

  Widget _categoryHeader(CanonCategory category, int count) {
    final collapsed = _collapsedCategories.contains(category);
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() {
        if (collapsed) {
          _collapsedCategories.remove(category);
        } else {
          _collapsedCategories.add(category);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 20,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Text(category.label, style: theme.textTheme.labelLarge),
            const SizedBox(width: 6),
            Text(
              '（$count）',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(CanonEntry entry) {
    final applied = entry.appliedId != null;
    return Card(
      child: ListTile(
        leading: Switch(value: entry.isEnabled, onChanged: (_) => _toggleEntry(entry)),
        title: Text(entry.title),
        subtitle: Text(
          '${entry.summary.isEmpty ? entry.detail : entry.summary}'
          '${entry.aliases.isEmpty ? '' : '\n别名：${entry.aliases.join('、')}'}'
          '${applied ? '\n已应用到 ${_appliedLabel(entry.appliedType)}' : ''}',
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') _editEntry(entry);
            if (value == 'merge') _mergeEntry(entry);
            if (value == 'disambiguate') _disambiguateEntry(entry);
            if (value == 'refine') _refineEntry(entry);
            if (value == 'apply') _applyEntry(entry);
            if (value == 'delete') _deleteEntry(entry);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            const PopupMenuItem(value: 'merge', child: Text('合并到…')),
            const PopupMenuItem(value: 'disambiguate', child: Text('联网消歧')),
            const PopupMenuItem(value: 'refine', child: Text('AI 归并')),
            PopupMenuItem(
              value: 'apply',
              child: Text(applied ? '更新已应用资料' : '应用到资料'),
            ),
            const PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
        onTap: () => _editEntry(entry),
      ),
    );
  }

  String _appliedLabel(String? type) {
    switch (type) {
      case 'character':
        return '角色库';
      case 'world-entry':
        return '世界书';
      case 'note':
        return '笔记';
      default:
        return '资料';
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}