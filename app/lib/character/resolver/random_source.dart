import 'dart:math';

abstract interface class RandomSource {
  double nextDouble();
}

class SeededRandomSource implements RandomSource {
  SeededRandomSource(int seed) : _random = Random(seed);

  final Random _random;

  @override
  double nextDouble() => _random.nextDouble();
}

class FixedRandomSource implements RandomSource {
  FixedRandomSource(Iterable<double> values) : _values = values.toList();

  final List<double> _values;
  var _index = 0;

  @override
  double nextDouble() {
    if (_values.isEmpty) return 0;
    final value = _values[_index % _values.length];
    _index += 1;
    return value.clamp(0, 0.999999999).toDouble();
  }
}
