import 'package:dio/dio.dart';

class HanaApiClient {
  HanaApiClient({Dio? dio}) : dio = dio ?? Dio();
  final Dio dio;
}
