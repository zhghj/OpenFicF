import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/style_repositories.dart';
import '../models.dart';
import '../services/active_model.dart';
import '../settings/lorn_style_plugin.dart';
import '../style/source_library.dart';
import '../widgets/common.dart';

class StyleLibraryScreen extends StatefulWidget {
  final Project project;

  const StyleLibraryScreen({super.key, required this.project});

  @override
  State<StyleLibraryScreen> createState() => _StyleLibraryScreenState();
}

class _StyleLibraryScreenState extends State<StyleLibraryScreen> {
  List<StyleSource> _sources = [];
  List<StyleProfile> _profiles = [];
  Set<String> _activeProfileIds = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sources = await listStyleSources();
      final profiles = await listStyleProfiles(widget.project.id);
      final active = await getActiveStyleProfiles(widget.project.id);
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _profiles = profiles;
        _activeProfileIds = active.map((profile) => profile.id).toSet();
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
      showMessageSnack(context, '正在导入并解析…');
      await importStyleSourceFromBytes(bytes: bytes, fileName: file.name);
      await _load();
      if (mounted) showMessageSnack(context, '导入完成');
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _distill(StyleSource source, {bool restart = false}) async {
    final selection = await getActiveModelSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    final progress = ValueNotifier<StyleDistillationProgress?>(null);
    var dismissible = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: dismissible,
        child: AlertDialog(
          title: Text('蒸馏《${source.title}》'),
          content: ValueListenableBuilder<StyleDistillationProgress?>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('正在用当前模型分析参考书样本，完整原书不会上传。'),
                const SizedBox(height: 16),
                if (value != null) ...[
                  LinearProgressIndicator(
                    value: value.total <= 0 ? null : value.completed / value.total,
                  ),
                  const SizedBox(height: 8),
                  Text(value.label),
                ] else
                  const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      final result = await distillReferenceStyle(
        sourceId: source.id,
        selection: selection,
        restart: restart,
        onProgress: (value) => progress.value = value,
      );
      dismissible = true;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      await _load();
      if (mounted) {
        showMessageSnack(
          context,
          '已保存参考文风 V${result.profile.version}，覆盖到 ${result.coverage.coveredUntil}/${result.coverage.totalUnits}',
        );
      }
    } catch (error) {
      dismissible = true;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _deleteSource(StyleSource source) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除参考书',
      message: '确定删除《${source.title}》吗？由它蒸馏出的参考文风版本也会一并删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteStyleSource(source.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  String? _sourceTitle(String? sourceId) {
  if (sourceId == null) return null;
  for (final source in _sources) {
    if (source.id == sourceId) return source.title;
  }
  return null;
}

Future<void> _toggleProfile(StyleProfile profile, bool enabled) async {
    try {
      await toggleActiveStyleProfile(widget.project.id, profile.id, enabled);
      await _load();
      if (mounted) {
        showMessageSnack(
          context,
          enabled ? '已启用：${profile.name} V${profile.version}' : '已停用：${profile.name} V${profile.version}',
        );
      }
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _clearActive() async {
    try {
      await setActiveStyleProfiles(widget.project.id, const []);
      await _load();
      if (mounted) showMessageSnack(context, '已停用全部文风');
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  void _viewGuide(StyleProfile profile) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text('${profile.name} V${profile.version}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SelectableText(profile.guide.isEmpty ? '（暂无内容）' : profile.guide,
              style: const TextStyle(height: 1.5)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _deleteProfile(StyleProfile profile) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除文风版本',
      message: '确定删除「${profile.name} V${profile.version}」吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteStyleProfile(profile.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final referenceProfiles =
        _profiles.where((profile) => profile.kind == StyleProfileKind.reference).toList();
    final authorProfiles =
        _profiles.where((profile) => profile.kind == StyleProfileKind.author).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('文风书库'),
        actions: [IconButton(onPressed: _import, icon: const Icon(Icons.add), tooltip: '导入参考书')],
      ),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('参考书', style: Theme.of(context).textTheme.titleMedium),
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
                      title: Text('还没有参考书'),
                      subtitle: Text('导入小说后，可用当前模型蒸馏出参考文风。完整原书不会上传。'),
                    ),
                  ),
                for (final source in _sources)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: Text(source.title),
                      subtitle: Text(
                        '${source.format.toUpperCase()} · ${source.characterCount} 字',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'distill') _distill(source);
                          if (value == 'restart') _distill(source, restart: true);
                          if (value == 'delete') _deleteSource(source);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'distill', child: Text('蒸馏 / 继续蒸馏')),
                          PopupMenuItem(value: 'restart', child: Text('重新开始蒸馏')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () => _distill(source),
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text('创作文风（已启用 ${_activeProfileIds.length} / ${_profiles.length}）',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    if (_activeProfileIds.isNotEmpty)
                      TextButton(onPressed: _clearActive, child: const Text('全部停用')),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text('可同时启用多份：多本参考文风与作者文风会一起注入写作提示。',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                for (final profile in [...authorProfiles, ...referenceProfiles])
                  Card(
                    color: _activeProfileIds.contains(profile.id)
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                    child: ListTile(
                      leading: Switch(
                        value: _activeProfileIds.contains(profile.id),
                        onChanged: (value) => _toggleProfile(profile, value),
                      ),
                      title: Text('${profile.name} V${profile.version}'),
                      subtitle: Text(
                        '${profile.kind == StyleProfileKind.author ? '作者文风' : '参考文风'} · '
                        '${profile.guide.length} 字'
                        '${_sourceTitle(profile.sourceId) == null ? '' : ' · 来源：${_sourceTitle(profile.sourceId)}'}',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'view') _viewGuide(profile);
                          if (value == 'toggle') _toggleProfile(profile, !_activeProfileIds.contains(profile.id));
                          if (value == 'delete') _deleteProfile(profile);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'view', child: Text('查看指南')),
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text(_activeProfileIds.contains(profile.id) ? '停用' : '启用'),
                          ),
                          const PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () => _viewGuide(profile),
                    ),
                  ),
                if (_profiles.isEmpty) ...[
                  const SizedBox(height: 8),
                  const Card(
                    child: ListTile(
                      title: Text('还没有文风版本'),
                      subtitle: Text('蒸馏参考书，或在写作页对 AI 原稿修改后进化作者文风。'),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}