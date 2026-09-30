import 'package:flutter/material.dart';

import '../data/repositories.dart';
import '../models.dart';
import '../widgets/common.dart';
import 'project_shell.dart';
import 'task_pool_screen.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  late Future<List<Project>> _future;

  @override
  void initState() {
    super.initState();
    _future = listProjects();
  }

  void _reload() {
    setState(() {
      _future = listProjects();
    });
  }

  Future<void> _createProject() async {
    final title = await promptText(context, title: '新建作品', hint: '作品名');
    if (title == null || title.isEmpty) return;
    try {
      await createProject(title);
      _reload();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _deleteProject(Project project) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除作品',
      message: '确定删除《${project.title}》吗？该作品的章节、角色、世界书和对话都会一并删除，且无法恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteProject(project.id);
      _reload();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _openProject(Project project) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProjectShell(projectId: project.id)),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          const TaskPoolButton(),
          IconButton(onPressed: _createProject, icon: const Icon(Icons.add), tooltip: '新建作品'),
        ],
      ),
      body: FutureBuilder<List<Project>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorView(error: snapshot.error!, onRetry: _reload);
          }
          final projects = snapshot.data ?? const [];
          if (projects.isEmpty) {
            return EmptyState(
              icon: Icons.menu_book_outlined,
              title: '书架还是空的',
              subtitle: '新建一部作品，开始本地创作。所有数据只保存在这台设备上。',
              action: FilledButton.icon(
                onPressed: _createProject,
                icon: const Icon(Icons.add),
                label: const Text('新建作品'),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: projects.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final project = projects[index];
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      child: Text(project.title.characters.first),
                    ),
                    title: Text(project.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      project.description.isEmpty
                          ? '更新于 ${formatTimestamp(project.updatedAt)}'
                          : '${project.description}\n更新于 ${formatTimestamp(project.updatedAt)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      onPressed: () => _deleteProject(project),
                    ),
                    onTap: () => _openProject(project),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}