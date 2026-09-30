import 'package:flutter/material.dart';

import '../data/observation_repositories.dart';
import '../data/project_controls_repositories.dart';
import '../data/story_state_repositories.dart';
import '../models.dart';
import '../story_models.dart';
import '../widgets/common.dart';

class StoryStateScreen extends StatefulWidget {
  final Project project;

  const StoryStateScreen({super.key, required this.project});

  @override
  State<StoryStateScreen> createState() => _StoryStateScreenState();
}

class _StoryStateScreenState extends State<StoryStateScreen> {
  StoryState _state = const StoryState();
  ProjectControls _controls = const ProjectControls();
  List<Observation> _observations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await getStoryState(widget.project.id);
      final controls = await getProjectControls(widget.project.id);
      final observations = await listProjectObservations(widget.project.id);
      if (!mounted) return;
      setState(() {
        _state = state;
        _controls = controls;
        _observations = observations;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  Future<void> _editControls() async {
    final intentController = TextEditingController(text: _controls.authorIntent);
    final focusController = TextEditingController(text: _controls.currentFocus);
    final personController = TextEditingController(text: _controls.narrativePerson);
    final wordsController = TextEditingController(text: '${_controls.chapterWordCount}');
    final prohibitionsController = TextEditingController(text: _controls.prohibitions.join('\n'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('创作控制'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: intentController,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '作者长期意图',
                  hintText: '这本书长期想成为什么',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: focusController,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '当前关注点',
                  hintText: '最近 1-3 章要把注意力拉回哪里',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: wordsController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '每章目标字数'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: personController,
                decoration: const InputDecoration(labelText: '叙事人称（可选）', hintText: '例如：第三人称限知'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: prohibitionsController,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '本书禁忌（每行一条）',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    try {
      await saveProjectControls(
        widget.project.id,
        ProjectControls(
          authorIntent: intentController.text.trim(),
          currentFocus: focusController.text.trim(),
          chapterWordCount: int.tryParse(wordsController.text.trim()) ?? _controls.chapterWordCount,
          narrativePerson: personController.text.trim(),
          prohibitions: prohibitionsController.text
              .split(RegExp(r'\r?\n'))
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toList(),
        ),
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _clearState() async {
    final confirmed = await confirmDialog(
      context,
      title: '清空故事状态',
      message: '将清空伏笔、章节摘要和当前状态事实（不影响正文、角色和世界书）。确定继续吗？',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed) return;
    await clearStoryState(widget.project.id);
    await _load();
  }

  Color _statusColor(HookStatus status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case HookStatus.open:
        return scheme.primary;
      case HookStatus.progressing:
        return scheme.tertiary;
      case HookStatus.deferred:
        return scheme.outline;
      case HookStatus.resolved:
        return scheme.secondary;
      case HookStatus.superseded:
        return scheme.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final openHooks = _state.openHooks;
    final facts = _state.facts.where((fact) => fact.active).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('故事状态'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') _editControls();
              if (value == 'clear') _clearState();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑创作控制')),
              PopupMenuItem(value: 'clear', child: Text('清空故事状态')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.flag_outlined),
                    title: const Text('创作控制'),
                    subtitle: Text(
                      '目标字数 ${_controls.chapterWordCount}'
                      '${_controls.narrativePerson.isEmpty ? '' : ' · ${_controls.narrativePerson}'}'
                      '\n作者意图：${_controls.authorIntent.isEmpty ? '未填写' : _controls.authorIntent}'
                      '\n当前关注：${_controls.currentFocus.isEmpty ? '未填写' : _controls.currentFocus}',
                    ),
                    isThreeLine: true,
                    trailing: IconButton(onPressed: _editControls, icon: const Icon(Icons.edit_outlined)),
                  ),
                ),
                const SizedBox(height: 16),
                _sectionTitle('未回收伏笔（${openHooks.length}）'),
                if (openHooks.isEmpty)
                  const Card(child: ListTile(title: Text('暂无未回收伏笔'))),
                for (final hook in openHooks)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: _statusColor(hook.status).withValues(alpha: 0.2),
                        child: Text('${hook.startChapter}',
                            style: TextStyle(fontSize: 11, color: _statusColor(hook.status))),
                      ),
                      title: Text('${hook.type} · ${hook.hookId}'),
                      subtitle: Text(
                        '状态 ${hook.status.wire} · 最近推进 第${hook.lastAdvancedChapter}章\n'
                        '预期回收：${hook.expectedPayoff.isEmpty ? '未填写' : hook.expectedPayoff}',
                      ),
                      isThreeLine: true,
                    ),
                  ),
                const SizedBox(height: 16),
                _sectionTitle('当前世界状态（${facts.length}）'),
                if (facts.isEmpty) const Card(child: ListTile(title: Text('暂无状态事实'))),
                for (final fact in facts)
                  Card(
                    child: ListTile(
                      dense: true,
                      title: Text('${fact.subject} · ${fact.predicate}'),
                      subtitle: Text('${fact.object}（自第${fact.validFromChapter}章）'),
                    ),
                  ),
                const SizedBox(height: 16),
                _sectionTitle('章节摘要（${_state.summaries.length}）'),
                if (_state.summaries.isEmpty)
                  const Card(child: ListTile(title: Text('暂无章节摘要，可用“写下一章”生成'))),
                for (final row in _state.summaries.reversed)
                  Card(
                    child: ListTile(
                      title: Text('第 ${row.chapter} 章 · ${row.title}'),
                      subtitle: Text(
                        '${row.events}${row.hookActivity.isEmpty ? '' : '\n伏笔：${row.hookActivity}'}',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                _sectionTitle('审稿意见（${_observations.length}）'),
                if (_observations.isEmpty) const Card(child: ListTile(title: Text('暂无审稿意见'))),
                for (final observation in _observations)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        observation.assessment == 'issue' ? Icons.error_outline : Icons.info_outline,
                        color: observation.assessment == 'issue'
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                      title: Text('${observation.code} · ${observation.assessment}'),
                      subtitle: Text(
                        '${observation.summary}'
                        '${observation.evidence.isEmpty ? '' : '\n证据：${observation.evidence.first}'}',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}