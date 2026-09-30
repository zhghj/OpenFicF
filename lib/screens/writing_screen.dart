import 'dart:async';

import 'package:flutter/material.dart';

import '../data/chapter_draft_repositories.dart';
import '../data/note_repositories.dart';
import '../data/observation_repositories.dart';
import '../data/repositories.dart';
import '../data/style_repositories.dart';
import '../models.dart';
import '../pipeline/chapter_pipeline.dart';
import '../services/active_model.dart';
import '../services/export_service.dart';
import '../settings/lorn_style_plugin.dart';
import '../story_models.dart';
import '../widgets/common.dart';
import 'notes_screen.dart';
import 'story_state_screen.dart';

class WritingScreen extends StatefulWidget {
  final Project project;

  const WritingScreen({super.key, required this.project});

  @override
  State<WritingScreen> createState() => _WritingScreenState();
}

class _WritingScreenState extends State<WritingScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  List<Volume> _volumes = [];
  List<Chapter> _chapters = [];
  Chapter? _selected;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  Timer? _autosaveTimer;
  ChapterDraftSnapshot? _pendingEvolution;
  List<StyleProfile> _activeStyles = [];
  List<Observation> _observations = [];
  bool _pipelineRunning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final volumes = await listVolumes(widget.project.id);
      final chapters = await listChapters(widget.project.id);
      final activeStyles = await getActiveStyleProfiles(widget.project.id);
      if (!mounted) return;
      final previous = _selected;
      Chapter? next = chapters.isEmpty ? null : chapters.first;
      if (previous != null) {
        for (final chapter in chapters) {
          if (chapter.id == previous.id) next = chapter;
        }
      }
      setState(() {
        _volumes = volumes;
        _chapters = chapters;
        _activeStyles = activeStyles;
        _loading = false;
        _selectChapter(next, notify: false);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  void _selectChapter(Chapter? chapter, {bool notify = true}) {
    _autosaveTimer?.cancel();
    _selected = chapter;
    _editing = false;
    _titleController.text = chapter?.title ?? '';
    _contentController.text = chapter?.content ?? '';
    _pendingEvolution = null;
    if (chapter != null) _loadPendingEvolution(chapter.id);
    if (notify) setState(() {});
  }

  Future<void> _loadPendingEvolution(String chapterId) async {
    try {
      final pending = await getPendingChapterStyleEvolution(chapterId);
      final observations = await listChapterObservations(chapterId);
      if (mounted) {
        setState(() {
          _pendingEvolution = pending;
          _observations = observations;
        });
      }
    } catch (_) {}
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(seconds: 2), () {
      _save(returnToPreview: false, silent: true);
    });
  }

  Future<void> _save({bool returnToPreview = true, bool silent = false}) async {
    final chapter = _selected;
    if (chapter == null) return;
    final title = _titleController.text.trim();
    final content = _contentController.text;
    if (title.isEmpty) {
      if (!silent && mounted) showMessageSnack(context, '章节标题不能为空');
      return;
    }
    if (content == chapter.content && title == chapter.title) {
        if (returnToPreview && mounted) setState(() => _editing = false);
      return;
    }
    setState(() => _saving = true);
    try {
      await saveChapter(chapter.id, title, content);
      await recordLatestAuthorRevision(chapter.id, content);
      final chapters = await listChapters(widget.project.id);
      if (!mounted) return;
        setState(() {
        _chapters = chapters;
        _saving = false;
        if (returnToPreview) _editing = false;
      });
      await _loadPendingEvolution(chapter.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (!silent) showErrorSnack(context, error);
    }
  }

  Future<void> _createVolume() async {
    final title = await promptText(context, title: '新建卷', hint: '卷名');
    if (title == null || title.isEmpty) return;
    try {
      await createVolume(widget.project.id, title);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _createChapter(Volume volume) async {
    final title = await promptText(context, title: '新建章节', hint: '章节标题');
    if (title == null || title.isEmpty) return;
    try {
      final chapter = await createChapter(widget.project.id, volume.id, title);
      await _load();
      _scaffoldKey.currentState?.closeDrawer();
      setState(() => _selectChapter(chapter));
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _renameChapter(Chapter chapter) async {
    final title = await promptText(context, title: '重命名章节', initialValue: chapter.title);
    if (title == null || title.isEmpty) return;
    try {
      await renameChapter(chapter.id, title);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _deleteChapter(Chapter chapter) async {
    final notes = await countNotesUnder(chapterId: chapter.id);
    if (!mounted) return;
    final confirmed = await confirmDialog(
      context,
      title: '删除章节',
      message: notes > 0
          ? '确定删除《${chapter.title}》吗？该章下有 $notes 条笔记，删除后笔记会自动上浮到上一级。'
          : '确定删除《${chapter.title}》吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteChapter(chapter.id);
      if (_selected?.id == chapter.id) _selected = null;
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _renameVolume(Volume volume) async {
    final title = await promptText(context, title: '重命名卷', initialValue: volume.title);
    if (title == null || title.isEmpty) return;
    try {
      await renameVolume(volume.id, title);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _deleteVolume(Volume volume) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除卷',
      message: '确定删除《${volume.title}》吗？该卷下的章节会一并删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteVolume(volume.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _export(ExportScope scope) async {
    await _save(returnToPreview: false, silent: true);
    try {
      await exportNovel(
        project: widget.project,
        volumes: _volumes,
        chapters: _chapters,
        scope: scope,
        chapterId: _selected?.id,
        volumeId: _selected?.volumeId,
      );
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _evolveStyle() async {
    final pending = _pendingEvolution;
    final chapter = _selected;
    if (pending == null || chapter == null) return;
    final selection = await getActiveModelSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    showMessageSnack(context, '正在用当前模型进化作者文风…');
    try {
      await evolveAuthorStyle(
        projectId: widget.project.id,
        aiDraft: pending.aiDraft,
        authorRevision: pending.authorRevision ?? '',
        selection: selection,
      );
      await markChapterStyleEvolved(pending.id);
      await _load();
      if (mounted) showMessageSnack(context, '已保存新的作者文风版本');
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _openNotes() async {
    final chapter = _selected;
    if (chapter == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NotesScreen(
        project: widget.project,
        initialVolumeId: chapter.volumeId,
        initialChapterId: chapter.id,
      ),
    ));
  }

  Future<void> _openStoryState() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StoryStateScreen(project: widget.project),
    ));
    await _load();
  }

  Future<void> _writeNextChapter() async {
    if (_pipelineRunning) return;
    final selection = await getActiveModelSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    final instruction = await promptText(
      context,
      title: '写下一章',
      hint: '本章的额外要求（可留空）',
      maxLines: 4,
      confirmLabel: '开始',
    );
    if (instruction == null || !mounted) return;

    final progress = ValueNotifier<ChapterPipelineProgress?>(null);
    var dismissible = false;
    setState(() => _pipelineRunning = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: dismissible,
        child: AlertDialog(
          title: const Text('写下一章'),
          content: ValueListenableBuilder<ChapterPipelineProgress?>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('规划 → 写作 → 审稿 → 状态结算 → 保存。'),
                const SizedBox(height: 16),
                if (value != null) Text(value.label) else const Text('正在准备…'),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      final result = await runChapterPipeline(
        project: widget.project,
        selection: selection,
        instruction: instruction,
        onProgress: (value) => progress.value = value,
      );
      dismissible = true;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      await _load();
      if (!mounted) return;
      Chapter? created;
      for (final chapter in _chapters) {
        if (chapter.id == result.chapterId) created = chapter;
      }
      if (created != null) setState(() => _selectChapter(created));
      if (!mounted) return;
      showMessageSnack(
        context,
        '已生成《${result.title}》约 ${result.wordCount} 字'
        '${result.settleError == null ? '' : '（状态结算未完成）'}',
      );
      if (result.observations.isNotEmpty) _showObservations();
    } catch (error) {
      dismissible = true;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) showErrorSnack(context, error);
    } finally {
      if (mounted) setState(() => _pipelineRunning = false);
    }
  }

  Future<void> _reviewChapter() async {
    final chapter = _selected;
    if (chapter == null || _pipelineRunning) return;
    final selection = await getActiveModelSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    setState(() => _pipelineRunning = true);
    showMessageSnack(context, '正在审稿…');
    try {
      final result = await reviewExistingChapter(
        project: widget.project,
        chapter: chapter,
        selection: selection,
      );
      await _loadPendingEvolution(chapter.id);
      if (mounted) {
        showMessageSnack(context, result.summary.isEmpty ? '审稿完成' : result.summary);
        if (result.observations.isNotEmpty) _showObservations();
      }
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    } finally {
      if (mounted) setState(() => _pipelineRunning = false);
    }
  }

  void _showObservations() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('审稿意见', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_observations.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('本章暂无审稿意见'))
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final observation in _observations)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          observation.assessment == 'issue' ? Icons.error_outline : Icons.info_outline,
                          color: observation.assessment == 'issue'
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                        title: Text('${observation.code} · ${observation.assessment}'),
                        subtitle: Text(
                          '${observation.summary}'
                          '${observation.evidence.isEmpty ? '' : '\n证据：${observation.evidence.join(' / ')}'}',
                        ),
                        isThreeLine: observation.evidence.isNotEmpty,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Chapter> _chaptersOf(String volumeId) =>
      _chapters.where((chapter) => chapter.volumeId == volumeId).toList();

  Widget _buildEditor(Chapter chapter) {
    final theme = Theme.of(context);
    return Column(
      children: [
        if (_activeStyles.isNotEmpty)
          Container(
            width: double.infinity,
            color: theme.colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              _activeStyles.length == 1
                  ? '当前文风：${_activeStyles.first.name} V${_activeStyles.first.version}'
                  : '当前文风（${_activeStyles.length}）：${_activeStyles.map((profile) => '${profile.name} V${profile.version}').join('、')}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: _editing
                    ? TextField(
                        controller: _titleController,
                        decoration: const InputDecoration(labelText: '章节标题'),
                      )
                    : Text(chapter.title,
                        style: theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              if (_editing)
                FilledButton.tonalIcon(
                  onPressed: _saving ? null : () => _save(),
                  icon: _saving
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('完成'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: () => setState(() => _editing = true),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
            ],
          ),
        ),
        Expanded(
          child: _editing
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _contentController,
                    onChanged: (_) => _scheduleAutosave(),
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      hintText: '在这里写正文…',
                      border: InputBorder.none,
                      filled: false,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: chapter.content.trim().isEmpty
                      ? Text('（本章暂无正文，点击“编辑”开始写作）',
                          style: TextStyle(color: theme.colorScheme.outline))
                      : SelectableText(chapter.content, style: const TextStyle(height: 1.6, fontSize: 16)),
                ),
        ),
        if (_pendingEvolution != null)
          Material(
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.auto_fix_high),
              title: const Text('检测到你对 AI 原稿的修改'),
              subtitle: const Text('可据此进化当前作品的作者文风'),
              trailing: FilledButton(onPressed: _evolveStyle, child: const Text('进化')),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapter = _selected;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(chapter?.title ?? '写作'),
        actions: [
          if (_pipelineRunning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.auto_awesome_outlined),
            tooltip: '长篇创作',
            onSelected: (value) {
              if (value == 'next') _writeNextChapter();
              if (value == 'review') _reviewChapter();
              if (value == 'observations') _showObservations();
              if (value == 'state') _openStoryState();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'next', child: Text('写下一章（Agent）')),
              PopupMenuItem(
                value: 'review',
                enabled: chapter != null,
                child: const Text('审稿本章'),
              ),
              PopupMenuItem(
                value: 'observations',
                enabled: chapter != null,
                child: Text('审稿意见（${_observations.length}）'),
              ),
              const PopupMenuItem(value: 'state', child: Text('故事状态')),
            ],
          ),
          IconButton(
            onPressed: chapter == null ? null : _openNotes,
            icon: const Icon(Icons.sticky_note_2_outlined),
            tooltip: '本页笔记',
          ),
          PopupMenuButton<ExportScope>(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出',
            onSelected: _export,
            itemBuilder: (_) => const [
              PopupMenuItem(value: ExportScope.chapter, child: Text('导出当前章节')),
              PopupMenuItem(value: ExportScope.volume, child: Text('导出当前卷')),
              PopupMenuItem(value: ExportScope.book, child: Text('导出全书')),
            ],
          ),
        ],
      ),
      drawer: _ChapterDrawer(
        volumes: _volumes,
        chaptersOf: _chaptersOf,
        selectedChapterId: _selected?.id,
        onSelect: (selected) {
          _save(returnToPreview: false, silent: true);
          setState(() => _selectChapter(selected));
          _scaffoldKey.currentState?.closeDrawer();
        },
        onCreateVolume: _createVolume,
        onCreateChapter: _createChapter,
        onRenameChapter: _renameChapter,
        onDeleteChapter: _deleteChapter,
        onRenameVolume: _renameVolume,
        onDeleteVolume: _deleteVolume,
      ),
      floatingActionButton: chapter == null
          ? null
          : FloatingActionButton(
              onPressed: () => _volumes.isEmpty ? _createVolume() : _createChapter(_volumes.first),
              tooltip: '新建章节',
              child: const Icon(Icons.add),
            ),
      body: _loading
          ? const LoadingView()
          : chapter == null
              ? EmptyState(
                  icon: Icons.article_outlined,
                  title: '还没有章节',
                  subtitle: '新建一个章节开始写作。',
                  action: FilledButton.icon(
                    onPressed: _volumes.isEmpty ? _createVolume : () => _createChapter(_volumes.first),
                    icon: const Icon(Icons.add),
                    label: Text(_volumes.isEmpty ? '新建卷' : '新建章节'),
                  ),
                )
              : _buildEditor(chapter),
    );
  }
}

class _ChapterDrawer extends StatelessWidget {
  final List<Volume> volumes;
  final List<Chapter> Function(String volumeId) chaptersOf;
  final String? selectedChapterId;
  final void Function(Chapter chapter) onSelect;
  final VoidCallback onCreateVolume;
  final void Function(Volume volume) onCreateChapter;
  final void Function(Chapter chapter) onRenameChapter;
  final void Function(Chapter chapter) onDeleteChapter;
  final void Function(Volume volume) onRenameVolume;
  final void Function(Volume volume) onDeleteVolume;

  const _ChapterDrawer({
    required this.volumes,
    required this.chaptersOf,
    required this.selectedChapterId,
    required this.onSelect,
    required this.onCreateVolume,
    required this.onCreateChapter,
    required this.onRenameChapter,
    required this.onDeleteChapter,
    required this.onRenameVolume,
    required this.onDeleteVolume,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: const Text('目录', style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: IconButton(icon: const Icon(Icons.add), tooltip: '新建卷', onPressed: onCreateVolume),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final volume in volumes) ...[
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(volume.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'rename') onRenameVolume(volume);
                          if (value == 'delete') onDeleteVolume(volume);
                          if (value == 'add') onCreateChapter(volume);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'add', child: Text('新建章节')),
                          PopupMenuItem(value: 'rename', child: Text('重命名')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ),
                    for (final chapter in chaptersOf(volume.id))
                      ListTile(
                        contentPadding: const EdgeInsets.only(left: 32, right: 8),
                        dense: true,
                        selected: chapter.id == selectedChapterId,
                        title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'rename') onRenameChapter(chapter);
                            if (value == 'delete') onDeleteChapter(chapter);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('重命名')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                        onTap: () => onSelect(chapter),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}