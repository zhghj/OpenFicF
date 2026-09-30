import '../canon_models.dart';
import '../data/canon_repositories.dart';
import '../models.dart';
import '../pipeline/canon_distiller.dart';
import 'task_pool.dart';

/// 把「蒸馏整部正典」加入全局任务池，立即返回，不阻塞界面。
/// 任务从该书当前断点继续，可暂停/继续/取消。
String enqueueCanonDistillation({
  required CanonSource source,
  required ModelSelection selection,
  int parallelism = 2,
}) {
  final task = TaskPool.instance.enqueue(
    title: '蒸馏正典《${source.title}》',
    subtitle: '时间线 · 角色卡 · 世界观 · 人物关系',
    tag: 'canon:${source.id}',
    run: (ctx) async {
      final latest = await getCanonSource(source.id) ?? source;
      final result = await distillCanonAll(
        source: latest,
        selection: selection,
        parallelism: parallelism,
        onBeforeStep: () async {
          await ctx.waitIfPaused();
          ctx.checkCancelled();
        },
        onProgress: (progress) => ctx.report(
          completed: progress.completed,
          total: progress.total,
          label: progress.label,
        ),
        onLog: ctx.log,
      );
      ctx.report(
        completed: result.source.chunkCount,
        total: result.source.chunkCount,
        label: '完成：新增 ${result.added} 条，合并 ${result.merged} 条',
      );
    },
  );
  return task.id;
}