import 'package:flutter/material.dart';

import '../core/utils.dart';
import '../tasks/task_pool.dart';
import '../widgets/common.dart';

class TaskPoolScreen extends StatelessWidget {
  const TaskPoolScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务池'),
        actions: [
          ListenableBuilder(
            listenable: TaskPool.instance,
            builder: (context, _) => TextButton(
              onPressed: TaskPool.instance.tasks.any((task) => task.status.isFinished)
                  ? TaskPool.instance.clearFinished
                  : null,
              child: const Text('清除已结束'),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: TaskPool.instance,
        builder: (context, _) {
          final tasks = TaskPool.instance.tasks.reversed.toList();
          if (tasks.isEmpty) {
            return const EmptyState(
              icon: Icons.task_alt,
              title: '任务池是空的',
              subtitle: '整部正典蒸馏等长任务会在这里排队执行，不阻塞其它功能。',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: tasks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) => _TaskCard(task: tasks[index]),
          );
        },
      ),
    );
  }
}

class _TaskCard extends StatefulWidget {
  final PoolTask task;

  const _TaskCard({required this.task});

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _expanded = false;

  String _clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final theme = Theme.of(context);
    final color = switch (task.status) {
      TaskStatus.completed => theme.colorScheme.primary,
      TaskStatus.failed => theme.colorScheme.error,
      TaskStatus.paused => theme.colorScheme.tertiary,
      TaskStatus.cancelled => theme.colorScheme.outline,
      _ => theme.colorScheme.primary,
    };
    final showProgress = task.status.isActive || task.status.isFinished;
    final eta = task.estimatedRemaining;
    final finishAt = task.estimatedFinishAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(task.title,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(task.status.label,
                      style: theme.textTheme.labelSmall?.copyWith(color: color)),
                ),
              ],
            ),
            if (task.subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(task.subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
              ),
            if (showProgress && task.total > 0) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: task.status == TaskStatus.completed ? 1 : task.fraction,
              ),
            ],
            const SizedBox(height: 6),
            // 预估时间：仅在进度更新时重算，不做每秒刷新。
            Row(
              children: [
                Icon(Icons.schedule, size: 13, color: theme.colorScheme.outline),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    task.status.isFinished
                        ? (task.status == TaskStatus.completed ? '已完成' : task.status.label)
                        : '${formatEstimatedTime(eta)}'
                            '${finishAt != null ? ' · 预计 ${_clock(finishAt)} 完成' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.status == TaskStatus.failed
                        ? errorText(task.error ?? '失败')
                        : (task.total > 0 ? '${task.completed}/${task.total} · ' : '') + task.label,
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (task.canPause)
                  IconButton(
                    tooltip: '暂停',
                    onPressed: () => TaskPool.instance.pause(task.id),
                    icon: const Icon(Icons.pause_circle_outline),
                  ),
                if (task.canResume)
                  IconButton(
                    tooltip: '继续',
                    onPressed: () => TaskPool.instance.resume(task.id),
                    icon: const Icon(Icons.play_circle_outline),
                  ),
                if (task.canCancel)
                  IconButton(
                    tooltip: '取消',
                    onPressed: () => TaskPool.instance.cancel(task.id),
                    icon: const Icon(Icons.cancel_outlined),
                  ),
                if (task.status == TaskStatus.failed || task.status == TaskStatus.cancelled)
                  IconButton(
                    tooltip: '重试（从断点继续）',
                    onPressed: () => TaskPool.instance.retry(task.id),
                    icon: const Icon(Icons.refresh),
                  ),
                if (task.status.isFinished)
                  IconButton(
                    tooltip: '移除',
                    onPressed: () => TaskPool.instance.remove(task.id),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const Divider(height: 16),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: theme.colorScheme.outline),
                    const SizedBox(width: 6),
                    Text('任务与工具输出',
                        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    if (task.logs.isNotEmpty)
                      Text('（${task.logs.length}）',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Container(
                height: 180,
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, right: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: task.logs.isEmpty
                    ? Text('（暂无日志）', style: theme.textTheme.bodySmall)
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: task.logs.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            task.logs[index],
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              height: 1.35,
                            ),
                          ),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 书架等处的实时任务角标按钮。
class TaskPoolButton extends StatelessWidget {
  const TaskPoolButton({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TaskPool.instance,
      builder: (context, _) {
        final active = TaskPool.instance.activeCount;
        return IconButton(
          tooltip: '任务池',
          color: color,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TaskPoolScreen()),
          ),
          icon: Badge(
            isLabelVisible: active > 0,
            label: Text('$active'),
            child: const Icon(Icons.task_alt),
          ),
        );
      },
    );
  }
}