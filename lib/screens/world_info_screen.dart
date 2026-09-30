import 'package:flutter/material.dart';

import '../data/repositories.dart';
import '../models.dart';
import '../services/export_service.dart';
import '../widgets/common.dart';

class WorldInfoScreen extends StatefulWidget {
  final Project project;

  const WorldInfoScreen({super.key, required this.project});

  @override
  State<WorldInfoScreen> createState() => _WorldInfoScreenState();
}

class _WorldInfoScreenState extends State<WorldInfoScreen> {
  WorldInfo? _worldInfo;
  List<WorldInfoEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final worldInfo = await getOrCreateWorldInfo(widget.project.id);
      final entries = await listWorldInfoEntries(worldInfo.id);
      if (!mounted) return;
      setState(() {
        _worldInfo = worldInfo;
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  Future<void> _editEntry([WorldInfoEntry? entry]) async {
    final titleController = TextEditingController(text: entry?.name ?? '');
    final contentController = TextEditingController(text: entry?.content ?? '');
    var enabled = entry?.isEnabled ?? true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(entry == null ? '新建世界书条目' : '编辑世界书条目'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentController,
                  maxLines: 8,
                  minLines: 4,
                  decoration: const InputDecoration(labelText: '设定内容', alignLabelWithHint: true),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用（参与检索与 Agent 上下文）'),
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
    if (saved != true || _worldInfo == null) return;
    try {
      await saveWorldInfoEntry(
        id: entry?.id,
        worldInfoId: _worldInfo!.id,
        name: titleController.text,
        content: contentController.text,
        isEnabled: enabled,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _deleteEntry(WorldInfoEntry entry) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除条目',
      message: '确定删除《${entry.name}》吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteWorldInfoEntry(entry.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _export(bool json) async {
    final worldInfo = _worldInfo;
    if (worldInfo == null) return;
    try {
      await exportWorldInfo(widget.project, worldInfo, _entries, json);
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final worldInfo = _worldInfo;
    return Scaffold(
      appBar: AppBar(
        title: Text(worldInfo?.name ?? '世界书'),
        actions: [
          if (_entries.isNotEmpty)
            PopupMenuButton<bool>(
              icon: const Icon(Icons.ios_share),
              tooltip: '导出',
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(value: false, child: Text('导出为 Markdown')),
                PopupMenuItem(value: true, child: Text('导出为 JSON')),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editEntry(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const LoadingView()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
              itemCount: _entries.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.public),
                      title: const Text('世界书说明'),
                      subtitle: Text(
                        worldInfo?.description.isEmpty ?? true ? '暂无说明' : worldInfo!.description,
                      ),
                      onTap: _editWorldInfo,
                    ),
                  );
                }
                final entry = _entries[index - 1];
                return Card(
                  child: ListTile(
                    leading: Icon(
                      entry.isEnabled ? Icons.bookmark : Icons.bookmark_border,
                      color: entry.isEnabled ? Theme.of(context).colorScheme.primary : null,
                    ),
                    title: Text(entry.name),
                    subtitle: Text(
                      entry.content.isEmpty ? '暂无内容' : entry.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') _editEntry(entry);
                        if (value == 'toggle') _toggleEntry(entry);
                        if (value == 'delete') _deleteEntry(entry);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(value: 'toggle', child: Text(entry.isEnabled ? '停用' : '启用')),
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                    onTap: () => _editEntry(entry),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _toggleEntry(WorldInfoEntry entry) async {
    try {
      await saveWorldInfoEntry(
        id: entry.id,
        worldInfoId: entry.worldInfoId,
        name: entry.name,
        content: entry.content,
        isEnabled: !entry.isEnabled,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _editWorldInfo() async {
    final worldInfo = _worldInfo;
    if (worldInfo == null) return;
    final nameController = TextEditingController(text: worldInfo.name);
    final descriptionController = TextEditingController(text: worldInfo.description);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('编辑世界书'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '名称')),
            const SizedBox(height: 12),
            TextField(
              controller: descriptionController,
              maxLines: 4,
              minLines: 2,
              decoration: const InputDecoration(labelText: '说明', alignLabelWithHint: true),
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
    try {
      await saveWorldInfo(
        id: worldInfo.id,
        projectId: worldInfo.projectId,
        name: nameController.text,
        description: descriptionController.text,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }
}