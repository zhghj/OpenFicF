import 'dart:math';

/// 参考书抽样的纯逻辑，与 OpenFicM 的 sampling.ts 对齐。
enum StyleUnitKind { chapter, segment }

class StyleSampleWindow {
  final int start;
  final int count;

  const StyleSampleWindow({required this.start, required this.count});
}

/// 每轮蒸馏抽取的单元数，也是全书均匀抽样时的样本上限。
const int analysisPassageCount = 24;

/// 单轮最大跳跃幅度相对窗口大小的倍数。
const int _maxJumpWindows = 4;

List<int> spreadIndices(int totalUnits, int count) {
  final size = count < totalUnits ? count : totalUnits;
  if (size <= 1) return [0];
  return List<int>.generate(
    size,
    (index) => ((totalUnits - 1) * index / max(1, size - 1)).round(),
  );
}

StyleSampleWindow? nextSampleWindow({
  required int totalUnits,
  required int coveredUntil,
  int windowSize = analysisPassageCount,
  Random? random,
}) {
  final size = max(1, windowSize);
  final total = max(0, totalUnits);
  final covered = max(0, min(coveredUntil, total));
  if (total < 1 || covered >= total) return null;
  if (covered < 1) return StyleSampleWindow(start: 0, count: min(size, total));
  final remaining = total - covered;
  if (remaining <= size * 2) {
    final start = max(covered, total - size);
    return StyleSampleWindow(start: start, count: total - start);
  }
  final rng = random ?? Random();
  final maximumJump = min(size * _maxJumpWindows, ((remaining - size) / 2).floor());
  final ratio = min(max(rng.nextDouble(), 0), 0.999999);
  final start = covered + (ratio * (maximumJump + 1)).floor();
  return StyleSampleWindow(start: start, count: min(size, total - start));
}

String describeWindow(StyleUnitKind kind, StyleSampleWindow window) {
  final unit = kind == StyleUnitKind.chapter ? '章' : '段';
  return '第 ${window.start + 1}-${window.start + window.count} $unit';
}