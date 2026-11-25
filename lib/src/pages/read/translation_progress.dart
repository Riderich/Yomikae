import 'dart:math';

/// Progress of the page translations started from the reader: how many
/// pages are queued and done, what the page being translated is at, and how
/// fast pages go, for a progress bar with an estimate of the time left.
class TranslationProgress {
  int total = 0;
  int done = 0;
  int failed = 0;

  /// Seconds each translated page took; pages translated before are not timed.
  final List<double> pageSeconds = [];

  /// 0-based page being translated, its current stage (an l18n key) and start.
  int? currentPage;
  String? stage;
  DateTime? pageStart;

  /// When the last queued page finished, to keep the result up for a moment.
  DateTime? finishedAt;

  bool get running => done < total;

  /// Whether to show the bar at [now]: while running and a few seconds after.
  bool visibleAt(DateTime now) => running || (finishedAt != null && now.difference(finishedAt!) < const Duration(seconds: 3));

  /// Queues [pages] more pages; starts over when nothing is running.
  void add(int pages) {
    if (!running) {
      total = 0;
      done = 0;
      failed = 0;
      pageSeconds.clear();
      finishedAt = null;
    }
    total += pages;
  }

  /// Takes back queued pages that will not be translated (a stopped range).
  void cancel(int pages, DateTime now) {
    total = max(done, total - pages);
    _checkFinished(now);
  }

  void startPage(int index, DateTime now) {
    currentPage = index;
    pageStart = now;
    stage = null;
  }

  /// A page done: [seconds] it took, or null for one translated before.
  void finishPage({double? seconds, bool ok = true, required DateTime now}) {
    done = min(total, done + 1);
    if (!ok) {
      failed++;
    } else if (seconds != null) {
      pageSeconds.add(seconds);
    }
    _checkFinished(now);
  }

  void _checkFinished(DateTime now) {
    if (!running) {
      finishedAt = now;
      currentPage = null;
      stage = null;
      pageStart = null;
    }
  }

  double? get secondsPerPage => pageSeconds.isEmpty ? null : pageSeconds.reduce((a, b) => a + b) / pageSeconds.length;

  double currentSeconds(DateTime now) => pageStart == null ? 0 : now.difference(pageStart!).inMilliseconds / 1000;

  /// Done share including the page under way, estimated from the average
  /// speed; null (indeterminate) for a lone page with nothing to go by.
  double? fraction(DateTime now) {
    if (total == 0) {
      return null;
    }
    final double? perPage = secondsPerPage;
    if (perPage == null) {
      return total == 1 && running ? null : done / total;
    }
    final double partial = running ? min(0.95, currentSeconds(now) / perPage) : 0;
    return min(1, (done + partial) / total);
  }

  /// Time left for the queued pages at the average speed, once one is timed.
  Duration? remaining(DateTime now) {
    final double? perPage = secondsPerPage;
    if (perPage == null || !running) {
      return null;
    }
    final double seconds = max(0, (total - done) * perPage - currentSeconds(now));
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
