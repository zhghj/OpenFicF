import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openfic_f/tasks/task_pool.dart';

Future<void> _settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  final pool = TaskPool.instance;

  setUp(() {
    pool.clearFinished();
    pool.maxConcurrency = 2;
  });

  test('任务完成后状态与进度正确', () async {
    final task = pool.enqueue(
      title: '示例任务',
      run: (ctx) async {
        ctx.report(completed: 1, total: 3, label: '第一步');
        await _settle(1);
        ctx.report(completed: 3, total: 3, label: '完成');
      },
    );
    await _settle(30);
    expect(task.status, TaskStatus.completed);
    expect(task.completed, 3);
    expect(task.total, 3);
  });

  test('并发上限约束同时运行的任务数', () async {
    pool.maxConcurrency = 1;
    final events = <String>[];
    pool.enqueue(
      title: 'A',
      run: (ctx) async {
        events.add('A-start');
        await _settle(20);
        events.add('A-end');
      },
    );
    pool.enqueue(
      title: 'B',
      run: (ctx) async {
        events.add('B-start');
        await _settle(20);
        events.add('B-end');
      },
    );
    await _settle(80);
    expect(events, ['A-start', 'A-end', 'B-start', 'B-end']);
  });

  test('暂停会挂起任务，继续后恢复，取消能终止', () async {
    var steps = 0;
    final task = pool.enqueue(
      title: '长任务',
      run: (ctx) async {
        for (var i = 0; i < 1000; i += 1) {
          await ctx.waitIfPaused();
          ctx.checkCancelled();
          steps += 1;
          ctx.report(completed: steps, total: 1000);
          await _settle(2);
        }
      },
    );

    await _settle(30);
    expect(task.status, TaskStatus.running);
    pool.pause(task.id);
    expect(task.status, TaskStatus.paused);
    final atPause = steps;
    await _settle(30);
    // 暂停后最多只允许一个在途步骤完成。
    expect(steps - atPause, lessThanOrEqualTo(1));

    pool.resume(task.id);
    expect(task.status, TaskStatus.running);
    await _settle(30);
    expect(steps, greaterThan(atPause));

    pool.cancel(task.id);
    await _settle(30);
    expect(task.status, TaskStatus.cancelled);
  });

  test('排队中的任务可被取消', () async {
    pool.maxConcurrency = 1;
    final running = pool.enqueue(
      title: '占用中',
      run: (ctx) async => _settle(60),
    );
    final queued = pool.enqueue(title: '排队中', run: (ctx) async {});
    expect(queued.status, TaskStatus.queued);
    pool.cancel(queued.id);
    expect(queued.status, TaskStatus.cancelled);
    await _settle(80);
    expect(running.status, TaskStatus.completed);
  });

  test('任务异常被捕获并标记失败', () async {
    final task = pool.enqueue(
      title: '会失败',
      run: (ctx) async => throw Exception('boom'),
    );
    await _settle(20);
    expect(task.status, TaskStatus.failed);
    expect(task.error, isNotNull);
  });

  test('未开始时有基于总步数的预估时间', () async {
    final completer = Completer<void>();
    final task = pool.enqueue(
      title: '预估',
      run: (ctx) async {
        ctx.report(completed: 0, total: 4);
        await completer.future;
      },
    );
    await _settle(20);
    expect(task.estimatedRemaining, isNotNull);
    expect(task.estimatedRemaining!.inSeconds, defaultSecondsPerStep * 4);
    completer.complete();
    await _settle(20);
  });

  test('失败任务可重试并重新排队', () async {
    var attempts = 0;
    final task = pool.enqueue(
      title: '会失败一次',
      run: (ctx) async {
        attempts += 1;
        if (attempts == 1) throw Exception('boom');
      },
    );
    await _settle(20);
    expect(task.status, TaskStatus.failed);
    pool.retry(task.id);
    await _settle(20);
    expect(task.status, TaskStatus.completed);
    expect(attempts, 2);
  });

  test('hasActiveTag 能识别进行中的同类任务', () async {
    final completer = Completer<void>();
    pool.enqueue(
      title: '带标签',
      tag: 'canon:s1',
      run: (ctx) async => completer.future,
    );
    await _settle(10);
    expect(pool.hasActiveTag('canon:s1'), isTrue);
    expect(pool.hasActiveTag('canon:s2'), isFalse);
    completer.complete();
    await _settle(20);
  });

  test('日志会被记录并可通过任务池读取', () async {
    final task = pool.enqueue(
      title: '日志',
      run: (ctx) async {
        ctx.log('第一步完成');
        ctx.log('第二步完成');
      },
    );
    await _settle(20);
    expect(task.logs, ['第一步完成', '第二步完成']);
  });
}