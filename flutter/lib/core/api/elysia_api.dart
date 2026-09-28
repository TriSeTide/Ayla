/// 爱莉档案 API（web api/elysia.ts 14 行）。
///
/// - GET /elysia/profile/ —— 应用级单例档案（未初始化 → 404）。
///
/// 消费点：LiveHubPage 的爱莉角标（`elysiaUserId = p.enabled ? p.user.id : null`，
/// `LiveHubPage.tsx:108–120`）。写接口（POST/PATCH，需管理员）前端不触发
/// （`api/elysia.ts:5–7`），故不带出。
library;

import '../models/elysia_profile.dart';
import '../net/dio_client.dart';

class AylaElysiaApi {
  const AylaElysiaApi._();

  /// GET /elysia/profile/ —— 读爱莉档案；未初始化（404）→ null。
  ///
  /// web 侧未初始化**抛错**、调用方 `.catch(() => {})` 静默降级
  /// （`LiveHubPage.tsx:110–119`）；Dart 侧把 404 归一为 null，其余错误仍抛
  /// （调用方同样静默降级，但错误可观测）。
  static Future<AylaElysiaProfile?> getProfile() async {
    try {
      final Map<String, dynamic> resp = await DioClient.instance
          .get<Map<String, dynamic>>('/elysia/profile/');
      return AylaElysiaProfile.fromJson(resp);
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }
}
