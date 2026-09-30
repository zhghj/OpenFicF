import 'package:flutter/material.dart';

import '../data/repositories.dart';
import '../models.dart';
import '../widgets/common.dart';
import 'assistant_screen.dart';
import 'library_screen.dart';
import 'settings_screen.dart';
import 'writing_screen.dart';

class ProjectShell extends StatefulWidget {
  final String projectId;

  const ProjectShell({super.key, required this.projectId});

  @override
  State<ProjectShell> createState() => _ProjectShellState();
}

class _ProjectShellState extends State<ProjectShell> {
  int _index = 0;
  Project? _project;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final project = await getProject(widget.projectId);
      if (!mounted) return;
      setState(() {
        _project = project;
        _error = project == null ? Exception('作品不存在') : null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: ErrorView(error: _error!, onRetry: _load),
      );
    }
    final project = _project;
    if (project == null) {
      return const Scaffold(body: LoadingView());
    }
    final tabs = [
      WritingScreen(project: project),
      AssistantScreen(project: project),
      LibraryScreen(project: project),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.edit_note_outlined), selectedIcon: Icon(Icons.edit_note), label: '写作'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: '助手'),
          NavigationDestination(icon: Icon(Icons.collections_bookmark_outlined), selectedIcon: Icon(Icons.collections_bookmark), label: '资料'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}