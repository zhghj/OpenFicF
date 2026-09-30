import 'package:flutter/material.dart';

import '../models.dart';
import 'canon_screen.dart';
import 'characters_screen.dart';
import 'notes_screen.dart';
import 'story_state_screen.dart';
import 'style_library_screen.dart';
import 'world_info_screen.dart';

class LibraryScreen extends StatelessWidget {
  final Project project;

  const LibraryScreen({super.key, required this.project});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('资料')),
      body: ListView(
        children: [
          _entry(
            context,
            icon: Icons.people_outline,
            title: '角色库',
            subtitle: '维护角色设定，Agent 可读取并同步',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => CharactersScreen(project: project)),
            ),
          ),
          _entry(
            context,
            icon: Icons.public,
            title: '世界书',
            subtitle: '记录已经成立的设定与规则',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => WorldInfoScreen(project: project)),
            ),
          ),
          _entry(
            context,
            icon: Icons.sticky_note_2_outlined,
            title: '笔记',
            subtitle: '整书 / 卷 / 章三级，存放大纲与伏笔',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => NotesScreen(project: project)),
            ),
          ),
          _entry(
            context,
            icon: Icons.auto_stories_outlined,
            title: '文风书库',
            subtitle: '导入参考书，蒸馏参考文风与作者文风',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => StyleLibraryScreen(project: project)),
            ),
          ),
          _entry(
            context,
            icon: Icons.track_changes_outlined,
            title: '故事状态',
            subtitle: '伏笔、章节摘要、当前状态与作者意图',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => StoryStateScreen(project: project)),
            ),
          ),
          _entry(
            context,
            icon: Icons.library_books_outlined,
            title: '同人正典',
            subtitle: '导入原作，分片蒸馏时间线、角色卡与世界观',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => CanonScreen(project: project)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entry(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Icon(icon),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}