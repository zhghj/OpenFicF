import 'package:flutter/material.dart';

import '../data/repositories.dart';
import '../models.dart';
import '../services/export_service.dart';
import '../widgets/common.dart';

class CharactersScreen extends StatefulWidget {
  final Project project;

  const CharactersScreen({super.key, required this.project});

  @override
  State<CharactersScreen> createState() => _CharactersScreenState();
}

class _CharactersScreenState extends State<CharactersScreen> {
  final _searchController = TextEditingController();
  List<Character> _characters = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final characters = await listCharacters(widget.project.id, _searchController.text);
      if (!mounted) return;
      setState(() {
        _characters = characters;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  Future<void> _edit([Character? character]) async {
    final nameController = TextEditingController(text: character?.name ?? '');
    final descriptionController = TextEditingController(text: character?.description ?? '');
    var favorited = character?.isFavorited ?? false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(character == null ? '新建角色' : '编辑角色'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '角色名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  maxLines: 8,
                  minLines: 4,
                  decoration: const InputDecoration(labelText: '角色设定', alignLabelWithHint: true),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('收藏为重要角色'),
                  value: favorited,
                  onChanged: (value) => setDialogState(() => favorited = value),
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
      await saveCharacter(
        id: character?.id,
        projectId: widget.project.id,
        name: nameController.text,
        description: descriptionController.text,
        isFavorited: favorited,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _delete(Character character) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除角色',
      message: '确定删除《${character.name}》吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteCharacter(character.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _export(bool json) async {
    try {
      await exportCharacters(widget.project, _characters, json);
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('角色库'),
        actions: [
          if (_characters.isNotEmpty)
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
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => _load(),
              decoration: InputDecoration(
                hintText: '搜索角色',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          _load();
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const LoadingView()
                : _characters.isEmpty
                    ? EmptyState(
                        icon: Icons.people_outline,
                        title: '还没有角色',
                        subtitle: '新建角色，或在对话中让 Agent 根据正文创建。',
                        action: FilledButton.icon(
                          onPressed: () => _edit(),
                          icon: const Icon(Icons.add),
                          label: const Text('新建角色'),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                        itemCount: _characters.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final character = _characters[index];
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                character.isFavorited ? Icons.star : Icons.person_outline,
                                color: character.isFavorited
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              title: Text(character.name),
                              subtitle: Text(
                                character.description.isEmpty ? '暂无设定' : character.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'edit') _edit(character);
                                  if (value == 'delete') _delete(character);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                                  PopupMenuItem(value: 'delete', child: Text('删除')),
                                ],
                              ),
                              onTap: () => _edit(character),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}