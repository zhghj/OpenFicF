import 'dart:async';

import 'package:flutter/foundation.dart';

/// 全局任务池：并发执行后台长任务（如整部正典蒸馏），支持排队、暂停/继续、取消与进度显示。
/// 任务之间彼此独立，进入池子后不阻塞界面，用户可继续使用其它功能。

/// 尚无实际进度时，每步经验耗时（秒），用于给出初始预估。
const int defaultSecondsPerStep = 25;

/// 把预估时长格式化为可读文本。
String formatEstimatedTime(Duration? duration) {
  if (duration == null) return '预计时间未知';
  if (duration.inSeconds <= 0) return '即将完成';
  if (duration.inSeconds < 60) return '预计剩余约 ${duration.inSeconds} 秒';
  if (duration.inMinutes < 60) {
    final seconds = duration.inSeconds - duration.inMinutes * 60;
    return '预计剩余约 ${duration.inMinutes} 分${seconds > 0 ? ' $seconds 秒' : ''}';
  }
  final minutes = duration.inMinutes - duration.inHours * 60;
  return '预计剩余约 ${duration.inHours} 小时${minutes > 0 ? ' $minutes 分' : ''}';
}

enum TaskStatus { queued, running, paused, completed, failed, cancelled }

extension TaskStatusLabel on TaskStatus {
  String get label {
    switch (this) {
      case TaskStatus.queued:
        return '排队中';
      case TaskStatus.running:
        return '进行中';
      case TaskStatus.paused:
        return '已暂停';
      case TaskStatus.completed:
        return '已完成';
      case TaskStatus.failed:
        return '失败';
      case TaskStatus.cancelled:
        return '已取消';
    }
  }

  bool get isActive => this == TaskStatus.queued || this == TaskStatus.running || this == TaskStatus.paused;
  bool get isFinished => this == TaskStatus.completed || this == TaskStatus.failed || this == TaskStatus.cancelled;
}

class TaskCancelled implements Exception {
  const TaskCancelled();
  @override
  String toString() => '任务已取消';
}

/// 提供给任务运行体的控制与进度接口。任务应在每个可中断点调用
/// [waitIfPaused] 与 [checkCancelled]，从而支持暂停/继续与取消。
abstract class TaskContext {
  String get taskId;

  void report({int? completed, int? total, String? label, String? subtitle});

  /// 追加一行任务/工具输出日志，显示在任务卡片的可展开区域。
  void log(String message);

  /// 若任务已被暂停，挂起直到恢复；若已取消则抛出 [TaskCancelled]。
  Future<void> waitIfPaused();

  /// 若任务已取消则抛出 [TaskCancelled]。
  void checkCancelled();
}

class _TaskContext implements TaskContext {
  _TaskContext(this._pool, this._task);

  final TaskPool _pool;
  final PoolTask _task;

  @override
  String get taskId => _task.id;

  @override
  void report({int? completed, int? total, String? label, String? subtitle}) {
    if (completed != null) _task.completed = completed;
    if (total != null) _task.total = total;
    if (label != null) _task.label = label;
    if (subtitle != null) _task.subtitle = subtitle;
    _pool._notify();
  }

  @override
  void log(String message) {
    final line = message.trim();
    if (line.isEmpty) return;
    _task.logs.add(line);
    if (_task.logs.length > 300) {
      _task.logs.removeRange(0, _task.logs.length - 300);
    }
    _pool._notify();
  }

  @override
  Future<void> waitIfPaused() async {
    while (_task._paused && !_task._cancelled) {
      _task._gate ??= Completer<void>();
      await _task._gate!.future;
    }
    checkCancelled();
  }

  @override
  void checkCancelled() {
    if (_task._cancelled) throw const TaskCancelled();
  }
}

class PoolTask {
  PoolTask({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.run,
    this.tag,
    this.onFinished,
  });

  final String id;
  final String title;
  String subtitle;
  /// 便于按用途查询（例如 `canon:<sourceId>`）。
  final String? tag;
  final Future<void> Function(TaskContext ctx) run;
  final void Function(PoolTask task)? onFinished;
  late final _TaskContext _ctx = _TaskContext(TaskPool.instance, this);

  TaskStatus status = TaskStatus.queued;
  int completed = 0;
  int total = 0;
  String label = '等待开始';
  Object? error;
  DateTime createdAt = DateTime.now();
  DateTime? startedAt;
  DateTime? finishedAt;
  final List<String> logs = [];

  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _gate;

  double get fraction => total > 0 ? (completed / total).clamp(0.0, 1.0) : 0.0;

  bool get canPause => status == TaskStatus.running;
  bool get canResume => status == TaskStatus.paused;
  bool get canCancel => status.isActive;

  /// 预估剩余时间。基于已用时间与已完成步长线性外推；未开始时用经验步长估算。
  /// 仅在进度更新（notify）时重新计算，不做每秒刷新。
  Duration? get estimatedRemaining {
    if (status.isFinished) return Duration.zero;
    if (total <= 0) return null;
    final started = startedAt;
    if (completed <= 0 || started == null) {
      return Duration(seconds: total * defaultSecondsPerStep);
    }
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    if (elapsedMs <= 0) return Duration(seconds: total * defaultSecondsPerStep);
    final perStepMs = elapsedMs / completed;
    final remaining = (perStepMs * (total - completed)).round();
    return Duration(milliseconds: remaining < 0 ? 0 : remaining);
  }

  DateTime? get estimatedFinishAt {
    if (status.isFinished) return finishedAt;
    final remaining = estimatedRemaining;
    return remaining == null ? null : DateTime.now().add(remaining);
  }
}

class TaskPool extends ChangeNotifier {
  TaskPool._();

  static final TaskPool instance = TaskPool._();

  final List<PoolTask> _tasks = [];
  int _running = 0;

  /// 同时运行的任务数（多线程任务池）。
  int maxConcurrency = 2;

  List<PoolTask> get tasks => List.unmodifiable(_tasks);
  List<PoolTask> get activeTasks => _tasks.where((task) => task.status.isActive).toList();
  int get runningCount => _running;
  int get activeCount => activeTasks.length;

  PoolTask enqueue({
    required String title,
    String subtitle = '',
    String? tag,
    required Future<void> Function(TaskContext ctx) run,
    void Function(PoolTask task)? onFinished,
  }) {
    final task = PoolTask(
      id: 'task-${DateTime.now().microsecondsSinceEpoch}-${_tasks.length}',
      title: title,
      subtitle: subtitle,
      tag: tag,
      run: run,
      onFinished: onFinished,
    );
    _tasks.add(task);
    _pump();
    return task;
  }

  /// 是否存在正在排队/运行/暂停的同类任务，避免重复发起长任务。
  bool hasActiveTag(String tag) =>
      _tasks.any((task) => task.tag == tag && task.status.isActive);

  void pause(String id) {
    final task = _find(id);
    if (task == null || task.status != TaskStatus.running) return;
    task._paused = true;
    task.status = TaskStatus.paused;
    _notify();
  }

  void resume(String id) {
    final task = _find(id);
    if (task == null || task.status != TaskStatus.paused) return;
    task._paused = false;
    task._gate?.complete();
    task._gate = null;
    task.status = TaskStatus.running;
    _notify();
    _pump();
  }

  void cancel(String id) {
    final task = _find(id);
    if (task == null || task.status.isFinished) return;
    task._cancelled = true;
    task._gate?.complete();
    task._gate = null;
    if (task.status == TaskStatus.queued || task.status == TaskStatus.paused) {
      // 尚未真正运行的任务直接标记取消；运行中的任务由协作式检查终止。
      task.status = TaskStatus.cancelled;
      task.finishedAt = DateTime.now();
      task.label = '已取消';
    }
    _notify();
    _pump();
  }

  /// 重试失败/取消的任务：从断点继续（任务运行体会重新读取最新进度）。
void retry(String id) {
  final task = _find(id);
  if (task == null || !task.status.isFinished || task.status == TaskStatus.completed) return;
  task._cancelled = false;
  task._paused = false;
  task._gate = null;
  task.error = null;
  task.completed = 0;
  task.total = 0;
  task.label = '等待重试';
  task.finishedAt = null;
  task.status = TaskStatus.queued;
  _notify();
  _pump();
}

void remove(String id) {
    final task = _find(id);
    if (task == null || !task.status.isFinished) return;
    _tasks.remove(task);
    _notify();
  }

  void clearFinished() {
    _tasks.removeWhere((task) => task.status.isFinished);
    _notify();
  }

  PoolTask? _find(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _pump() {
    for (final task in _tasks) {
      if (_running >= maxConcurrency) break;
      if (task.status != TaskStatus.queued) continue;
      _start(task);
    }
  }

  void _start(PoolTask task) {
    _running += 1;
    task.status = TaskStatus.running;
    task.startedAt = DateTime.now();
    task.label = '开始';
    _notify();
    () async {
      try {
        await task.run(task._ctx);
        task.status = TaskStatus.completed;
        task.completed = task.total > 0 ? task.total : task.completed;
        task.label = '已完成';
      } on TaskCancelled {
        task.status = TaskStatus.cancelled;
        task.label = '已取消';
      } catch (error) {
        task.status = TaskStatus.failed;
        task.error = error;
        task.label = '$error';
      } finally {
        task.finishedAt = DateTime.now();
        _running -= 1;
        try {
          task.onFinished?.call(task);
        } catch (_) {}
        _notify();
        _pump();
      }
    }();
  }

  void _notify() => notifyListeners();
}