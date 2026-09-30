import 'package:flutter/material.dart';

import '../data/note_repositories.dart';
import '../data/repositories.dart';
import '../models.dart';
import '../widgets/common.dart';

class NotesScreen extends StatefulWidget {
  final Project project;
  final String? initialVolumeId;
  final String? initialChapterId;

  const NotesScreen({
    super.key,
    required this.project,
    this.initialVolumeId,
    this.initialChapterId,
  });

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<Volume> _volumes = [];
  List<Chapter> _chapters = [];
  List<Note> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final volumes = await listVolumes(widget.project.id);
      final chapters = await listChapters(widget.project.id);
      final notes = await listNotes(widget.project.id);
      if (!mounted) return;
      setState(() {
        _volumes = volumes;
        _chapters = chapters;
        _notes = notes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  List<Note> _projectNotes() =>
      _notes.where((note) => note.scope == NoteScope.project).toList();

  List<Note> _volumeNotes(String volumeId) =>
      _notes.where((note) => note.scope == NoteScope.volume && note.volumeId == volumeId).toList();

  List<Note> _chapterNotes(String chapterId) =>
      _notes.where((note) => note.scope == NoteScope.chapter && note.chapterId == chapterId).toList();

  Future<void> _createNote({String? volumeId, String? chapterId}) async {
    final created = await _editDialog(volumeId: volumeId, chapterId: chapterId);
    if (created) await _load();
  }

  Future<bool> _editDialog({
    Note? note,
    String? volumeId,
    String? chapterId,
  }) async {
    final titleController = TextEditingController(text: note?.title ?? '');
    final contentController = TextEditingController(text: note?.content ?? '');
    var scope = note?.scope ??
        (chapterId != null
            ? NoteScope.chapter
            : (volumeId != null ? NoteScope.volume : NoteScope.project));
    var selectedVolume = note?.volumeId ?? volumeId ?? (_volumes.isEmpty ? null : _volumes.first.id);
    var selectedChapter = note?.chapterId ??
        chapterId ??
        _firstChapterOf(selectedVolume);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(note == null ? '新建笔记' : '编辑笔记'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentController,
                  maxLines: 6,
                  minLines: 3,
                  decoration: const InputDecoration(labelText: '内容', alignLabelWithHint: true),
                ),
                const SizedBox(height: 16),
                SegmentedButton<NoteScope>(
                  segments: const [
                    ButtonSegment(value: NoteScope.project, label: Text('整书')),
                    ButtonSegment(value: NoteScope.volume, label: Text('卷')),
                    ButtonSegment(value: NoteScope.chapter, label: Text('章')),
                  ],
                  selected: {scope},
                  onSelectionChanged: (value) {
                    setDialogState(() {
                      scope = value.first;
                      selectedVolume ??= _volumes.isEmpty ? null : _volumes.first.id;
                      if (scope == NoteScope.chapter) {
                        selectedChapter ??= _firstChapterOf(selectedVolume);
                      }
                    });
                  },
                ),
                if (scope != NoteScope.project && _volumes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: selectedVolume,
                    decoration: const InputDecoration(labelText: '归属卷'),
                    items: _volumes
                        .map((volume) => DropdownMenuItem(value: volume.id, child: Text(volume.title)))
                        .toList(),
                    onChanged: (value) => setDialogState(() {
                      selectedVolume = value;
                      selectedChapter = _firstChapterOf(value);
                    }),
                  ),
                ],
                if (scope == NoteScope.chapter && selectedVolume != null) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: selectedChapter,
                    decoration: const InputDecoration(labelText: '归属章节'),
                    items: _chapters
                        .where((chapter) => chapter.volumeId == selectedVolume)
                        .map((chapter) => DropdownMenuItem(value: chapter.id, child: Text(chapter.title)))
                        .toList(),
                    onChanged: (value) => setDialogState(() => selectedChapter = value),
                  ),
                ],
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
    if (result != true) return false;
    try {
      if (note == null) {
        await createNote(
          projectId: widget.project.id,
          title: titleController.text,
          content: contentController.text,
          volumeId: scope == NoteScope.project ? null : selectedVolume,
          chapterId: scope == NoteScope.chapter ? selectedChapter : null,
        );
      } else {
        await updateNote(
          id: note.id,
          title: titleController.text,
          content: contentController.text,
        );
      }
      return true;
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
      return false;
    }
  }

  String? _firstChapterOf(String? volumeId) {
    if (volumeId == null) return null;
    for (final chapter in _chapters) {
      if (chapter.volumeId == volumeId) return chapter.id;
    }
    return null;
  }

  Future<void> _moveNote(Note note) async {
    var scope = note.scope;
    var selectedVolume = note.volumeId ?? (_volumes.isEmpty ? null : _volumes.first.id);
    var selectedChapter = note.chapterId ?? _firstChapterOf(selectedVolume);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('移动笔记归属'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<NoteScope>(
                segments: const [
                  ButtonSegment(value: NoteScope.project, label: Text('整书')),
                  ButtonSegment(value: NoteScope.volume, label: Text('卷')),
                  ButtonSegment(value: NoteScope.chapter, label: Text('章')),
                ],
                selected: {scope},
                onSelectionChanged: (value) => setDialogState(() {
                  scope = value.first;
                  selectedVolume ??= _volumes.isEmpty ? null : _volumes.first.id;
                  if (scope == NoteScope.chapter) selectedChapter ??= _firstChapterOf(selectedVolume);
                }),
              ),
              if (scope != NoteScope.project && _volumes.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: selectedVolume,
                  decoration: const InputDecoration(labelText: '归属卷'),
                  items: _volumes
                      .map((volume) => DropdownMenuItem(value: volume.id, child: Text(volume.title)))
                      .toList(),
                  onChanged: (value) => setDialogState(() {
                    selectedVolume = value;
                    selectedChapter = _firstChapterOf(value);
                  }),
                ),
              ],
              if (scope == NoteScope.chapter && selectedVolume != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: selectedChapter,
                  decoration: const InputDecoration(labelText: '归属章节'),
                  items: _chapters
                      .where((chapter) => chapter.volumeId == selectedVolume)
                      .map((chapter) => DropdownMenuItem(value: chapter.id, child: Text(chapter.title)))
                      .toList(),
                  onChanged: (value) => setDialogState(() => selectedChapter = value),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('移动')),
          ],
        ),
      ),
    );
    if (result != true) return;
    try {
      await moveNote(
        note.id,
        volumeId: scope == NoteScope.project ? null : selectedVolume,
        chapterId: scope == NoteScope.chapter ? selectedChapter : null,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _deleteNote(Note note) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除笔记',
      message: '确定删除《${note.title}》吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteNote(note.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Widget _noteTile(Note note) {
    return Card(
      child: ListTile(
        title: Text(note.title),
        subtitle: Text(
          note.content.isEmpty ? '暂无内容' : note.content,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') {
              _editDialog(note: note).then((done) {
                if (done) _load();
              });
            }
            if (value == 'move') _moveNote(note);
            if (value == 'delete') _deleteNote(note);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑')),
            PopupMenuItem(value: 'move', child: Text('移动归属')),
            PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
        onTap: () => _editDialog(note: note).then((done) {
          if (done) _load();
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记'),
        actions: [
          IconButton(
            tooltip: '新建整书笔记',
            onPressed: () => _createNote(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
              children: [
                _sectionHeader('整书', () => _createNote()),
                for (final note in _projectNotes()) _noteTile(note),
                for (final volume in _volumes) ...[
                  const SizedBox(height: 16),
                  _sectionHeader(
                    '卷 · ${volume.title}',
                    () => _createNote(volumeId: volume.id),
                  ),
                  for (final note in _volumeNotes(volume.id)) _noteTile(note),
                  for (final chapter in _chapters.where((chapter) => chapter.volumeId == volume.id)) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('章 · ${chapter.title}',
                                style: Theme.of(context).textTheme.labelLarge),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.add, size: 18),
                            onPressed: () => _createNote(volumeId: volume.id, chapterId: chapter.id),
                          ),
                        ],
                      ),
                    ),
                    for (final note in _chapterNotes(chapter.id)) _noteTile(note),
                  ],
                ],
              ],
            ),
    );
  }

  Widget _sectionHeader(String title, VoidCallback onAdd) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          IconButton(onPressed: onAdd, icon: const Icon(Icons.add)),
        ],
      ),
    );
  }
}