// G3 诊断探针：dio 直连 login + refresh，区分端点契约 vs DioClient 逻辑问题。
// Windows 侧运行：cmd.exe /c "dart.bat run tool\dio_probe.dart"
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:dio/dio.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:8100/api/v1',
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
  ));

  // 1) login
  final r = await dio.post<Map<String, dynamic>>(
    '/auth/login/',
    data: <String, String>{'username': '123', 'password': '12345678'},
    options: Options(headers: <String, String>{'Content-Type': 'application/json'}),
  );
  final String access = r.data?['access'] as String? ?? '';
  final String refresh = r.data?['refresh'] as String? ?? '';
  print('probe_login status=${r.statusCode} access=${access.isNotEmpty} refresh=${refresh.isNotEmpty}');

  // 2) refresh（立即，使用 login 返回的 refresh）
  try {
    final r2 = await dio.post<Map<String, dynamic>>(
      '/auth/refresh/',
      data: <String, String>{'refresh': refresh},
      options: Options(headers: <String, String>{'Content-Type': 'application/json'}),
    );
    print('probe_refresh status=${r2.statusCode} keys=${r2.data?.keys.toList()} '
        'newAccess=${(r2.data?['access'] as String? ?? '').isNotEmpty}');
  } on DioException catch (e) {
    print('probe_refresh ERR status=${e.response?.statusCode} body=${jsonEncode(e.response?.data)} type=${e.type}');
  }

  // 3) refresh 第二发（验证轮换后旧 refresh 是否失效——ROTATE_REFRESH_TOKENS 语义）
  try {
    await dio.post<Map<String, dynamic>>(
      '/auth/refresh/',
      data: <String, String>{'refresh': refresh},
      options: Options(headers: <String, String>{'Content-Type': 'application/json'}),
    );
    print('probe_refresh2 reuse old refresh: OK（旧 refresh 仍有效？）');
  } on DioException catch (e) {
    print('probe_refresh2 reuse old refresh: ERR status=${e.response?.statusCode} '
        'body=${jsonEncode(e.response?.data)}（轮换后旧 refresh 已失效=符合 ROTATE 语义）');
  }
}
