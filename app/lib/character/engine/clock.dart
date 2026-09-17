abstract interface class Clock {
  DateTime now();
}

class SystemClock implements Clock {
  const SystemClock();

  static final DateTime _origin = DateTime.now();
  static final Stopwatch _elapsed = Stopwatch()..start();

  @override
  DateTime now() => _origin.add(_elapsed.elapsed);
}

class FakeClock implements Clock {
  FakeClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;

  void advance(Duration duration) => current = current.add(duration);
}
