import 'dart:async';

import 'clock.dart';

abstract interface class TimerDriver {
  void schedule(String tag, DateTime at, void Function() callback);
  void cancel(String tag);
  void cancelAll();
}

class SystemTimerDriver implements TimerDriver {
  SystemTimerDriver(this.clock);

  final Clock clock;
  final Map<String, Timer> _timers = {};

  @override
  void schedule(String tag, DateTime at, void Function() callback) {
    cancel(tag);
    final delay = at.difference(clock.now());
    _timers[tag] = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timers.remove(tag);
      callback();
    });
  }

  @override
  void cancel(String tag) => _timers.remove(tag)?.cancel();

  @override
  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}

class FakeTimerDriver implements TimerDriver {
  FakeTimerDriver(this.clock);

  final FakeClock clock;
  final Map<String, ({DateTime at, void Function() callback})> _scheduled = {};

  Set<String> get tags => Set.unmodifiable(_scheduled.keys);

  @override
  void schedule(String tag, DateTime at, void Function() callback) {
    _scheduled[tag] = (at: at, callback: callback);
  }

  @override
  void cancel(String tag) => _scheduled.remove(tag);

  @override
  void cancelAll() => _scheduled.clear();

  void elapse(Duration duration) {
    clock.advance(duration);
    runDue();
  }

  void runDue() {
    while (true) {
      final due =
          _scheduled.entries
              .where((entry) => !entry.value.at.isAfter(clock.now()))
              .toList()
            ..sort((a, b) => a.value.at.compareTo(b.value.at));
      if (due.isEmpty) return;
      final first = due.first;
      _scheduled.remove(first.key);
      first.value.callback();
    }
  }
}
