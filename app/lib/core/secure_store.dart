import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class HanaSecureStore {
  const HanaSecureStore({this.storage = const FlutterSecureStorage()});
  final FlutterSecureStorage storage;
}
