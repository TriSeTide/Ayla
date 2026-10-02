/// 表情包域 API —— web `api/emoji.ts`（83 行）的 Dart 等价物。
///
/// ## 逐条对应
/// | 本方法 | web |
/// |---|---|
/// | [AylaEmojiApi.getGroupEmojiPackSummary] | `api/emoji.ts:33-35`（`GET .../pack/?summary=1`） |
/// | [AylaEmojiApi.listGroupEmojiItemsPage] | `api/emoji.ts:37-39`（`GET .../pack/items/?pagination=cursor&limit=30&cursor=`） |
/// | [AylaEmojiApi.setGroupEmojiUploadPolicy] | `api/emoji.ts:62-67`（`PATCH .../pack/?summary=1` 的 `{allow_member_upload}`） |
/// | [AylaEmojiApi.addGroupEmojiItem] | `api/emoji.ts:70-75`（`POST .../pack/items/` 的 `{media_id, tag}`） |
/// | [AylaEmojiApi.deleteGroupEmojiItem] | `api/emoji.ts:78-82`（`DELETE .../pack/items/<id>/` → 204） |
/// | [AylaEmojiApi.loadGroupEmojiPackSummary] | `EmojiPackPanel.tsx:75-80` + `GroupInfo.tsx:226-242`（404 ⇒ 空态 / 默认 false，**不算错误**） |
///
/// 路径挂 `/api/v1/emoji/`（[DioClient] 已带 kApiPrefix；web `client.ts` 同）。
/// 分页参数对齐 web `api/mediaPagination.ts:17-19`：
/// `pagination=cursor` 恒发、`limit` 默认 30、`cursor` 仅非空时带。
///
/// ## 404 纪律（后端 apps/emoji/views.py:228-232）
/// 群未建包时后端返回 **404 + detail=group_pack_not_found** —— 这是**业务空态**，
/// 不是致命错误（web `api/emoji.ts:56` 注释原文：「包未创建时后端返回 404
/// （调用方按空态处理）」）：
/// - [getGroupEmojiPackSummary] 抛出 [AylaEmojiPackMissingException]（[ApiException] 子类，
///   status == 404），调用方可按类型或状态码识别；
/// - [loadGroupEmojiPackSummary] 把它收敛成 [AylaGroupEmojiPackLoad.missing]（调用方零分支）。
///
/// 但**只认 detail == group_pack_not_found**：同端点还有另外两种 404
/// （「群不存在」，views.py:224-226）与 403（非群成员，views.py:226-227）——那些是真实错误，
/// 必须照常上报，不得被空态吞掉。
///
/// ## 公开面
/// AylaEmojiApi · AylaGroupEmojiPackPayload · AylaEmojiPackMissingException ·
/// AylaEmojiFailure · AylaGroupEmojiPackLoad · kAylaEmojiPackMissingDetail
library;

import '../models/emoji_item.dart';
import '../net/dio_client.dart';
import 'directory_page.dart';

/// 群表情包摘要响应 —— web GroupEmojiPackSummaryPayload（api/emoji.ts:17 / 42-50）。
///
/// 摘要档的 pack 走 EmojiPackBriefSerializer（后端 serializers.py:46-55：无 items）
/// ⇒ 只取 id / name / item_count；items 由 [AylaEmojiApi.listGroupEmojiItemsPage] 分页取。
class AylaGroupEmojiPackPayload {
  const AylaGroupEmojiPackPayload({
    required this.packId,
    this.packName = '',
    this.itemCount = 0,
    this.allowMemberUpload = false,
    this.canUpload = false,
    this.canDelete = false,
  });

  /// 包 id（pack.id）。
  final String packId;

  /// 包名（pack.name；群包由后端创建，缺省空串）。
  final String packName;

  /// 包内表情总数（pack.item_count）。
  final int itemCount;

  /// 群主设置的「允许普通群成员上传」开关（allow_member_upload）。
  final bool allowMemberUpload;

  /// 当前用户是否可上传（can_upload）。
  final bool canUpload;

  /// 当前用户是否可删除（can_delete）。
  final bool canDelete;

  /// 解析；缺 pack.id 视为非法 → null（不造空 id）。
  static AylaGroupEmojiPackPayload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? pack = raw['pack'];
    if (pack is! Map) return null;
    final Object? id = pack['id'];
    if (id == null) return null;
    return AylaGroupEmojiPackPayload(
      packId: id.toString(),
      packName: (pack['name'] as String?) ?? '',
      itemCount: (pack['item_count'] as num?)?.toInt() ?? 0,
      allowMemberUpload: raw['allow_member_upload'] == true,
      canUpload: raw['can_upload'] == true,
      canDelete: raw['can_delete'] == true,
    );
  }
}

/// 群**未建包** —— 后端 404 detail=group_pack_not_found（views.py:230-232）。
///
/// 继承 [ApiException] ⇒ 既有 catch (ApiException) / catch (e) 全部照常工作
/// （只是多了一种可分类识别的类型），不引入第二套异常体系。
class AylaEmojiPackMissingException extends ApiException {
  const AylaEmojiPackMissingException([Map<String, dynamic>? body])
      : super(404, kAylaEmojiPackMissingDetail, body);
}

/// 后端 404 的判据字面量（views.py:231 的 {"detail": "group_pack_not_found"}）。
///
/// 与 web EmojiPackPanel.tsx:77 的 e.message === "group_pack_not_found" 是同一个判据。
const String kAylaEmojiPackMissingDetail = 'group_pack_not_found';

/// 一次失败的可观测记录（面板/页面的错误回执；web 侧是 React state）。
class AylaEmojiFailure {
  const AylaEmojiFailure({
    required this.action,
    required this.message,
    this.itemId,
    this.mediaId,
  });

  /// 动作名：send / delete / policy。
  final String action;

  /// 归一化后的可读文案（ApiException.message）。
  final String message;

  /// 相关表情项 id（删除失败时）。
  final String? itemId;

  /// 相关媒体 id（发送失败时）。
  final String? mediaId;

  @override
  String toString() => 'AylaEmojiFailure($action): $message';
}

/// 摘要加载结果 —— 把「404 = 空态」这条 web 语义收敛在一处
/// （EmojiPackPanel.tsx:75-80 与 GroupInfo.tsx:232-240 是同一分支的两次抄写）。
class AylaGroupEmojiPackLoad {
  const AylaGroupEmojiPackLoad({this.payload, this.missing = false, this.error});

  /// 已建包时的摘要（null = 未建包或出错）。
  final AylaGroupEmojiPackPayload? payload;

  /// 后端 404 group_pack_not_found（包未创建 ⇒ 调用方按空态处理）。
  final bool missing;

  /// 其它错误的可读文案（null = 无错）。
  final String? error;

  /// 状态已定（含「确认未建包」这一确定状态）。
  bool get settled => payload != null || missing || error == null;

  /// 上传策略开关的生效值 —— web GroupInfo.tsx:234-236：
  /// 404 ⇒ allow_member_upload = false；成功 ⇒ 后端值。
  bool get allowMemberUpload => payload?.allowMemberUpload ?? false;
}

/// 表情包 API（静态方法类，与 AylaChatApi 同风格）。
class AylaEmojiApi {
  const AylaEmojiApi._();

  /// `GET /emoji/groups/<conv_id>/pack/?summary=1` —— 群表情包摘要。
  ///
  /// 包未创建 ⇒ 抛 [AylaEmojiPackMissingException]（404）；其它错误 ⇒ 普通 [ApiException]。
  static Future<AylaGroupEmojiPackPayload> getGroupEmojiPackSummary(
    String convId,
  ) async {
    try {
      final Map<String, dynamic> resp =
          await DioClient.instance.get<Map<String, dynamic>>(
        '/emoji/groups/${Uri.encodeComponent(convId)}/pack/',
        query: <String, dynamic>{'summary': '1'},
      );
      final AylaGroupEmojiPackPayload? payload =
          AylaGroupEmojiPackPayload.fromJson(resp);
      if (payload == null) {
        throw const ApiException(0, '群表情包响应格式不合法');
      }
      return payload;
    } on ApiException catch (e) {
      // 只把「本群未建包」当空态；「群不存在」/403 原样上抛
      // （web 同：EmojiPackPanel.tsx:77 判 status === 404 && message === "group_pack_not_found"）。
      if (e.status == 404 && e.message == kAylaEmojiPackMissingDetail) {
        throw AylaEmojiPackMissingException(e.body);
      }
      rethrow;
    }
  }

  /// `GET /emoji/groups/<conv_id>/pack/items/?pagination=cursor&limit=&cursor=`
  /// —— 群表情项游标页（web listGroupEmojiItemsPage，默认 limit 30）。
  static Future<AylaDirectoryPage<AylaEmojiItem>> listGroupEmojiItemsPage(
    String convId, {
    int limit = 30,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final Map<String, dynamic> resp =
        await DioClient.instance.get<Map<String, dynamic>>(
      '/emoji/groups/${Uri.encodeComponent(convId)}/pack/items/',
      query: query,
    );
    return AylaDirectoryPage.fromJson<AylaEmojiItem>(
      resp,
      AylaEmojiItem.fromJson,
    );
  }

  /// `PATCH /emoji/groups/<conv_id>/pack/?summary=1` —— 群主设置 allow_member_upload
  /// （后端 views.py:235-252：非群主 403）。
  static Future<AylaGroupEmojiPackPayload> setGroupEmojiUploadPolicy(
    String convId,
    bool allowMemberUpload,
  ) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.patch<Map<String, dynamic>>(
      '/emoji/groups/${Uri.encodeComponent(convId)}/pack/',
      query: <String, dynamic>{'summary': '1'},
      body: <String, dynamic>{'allow_member_upload': allowMemberUpload},
    );
    final AylaGroupEmojiPackPayload? payload =
        AylaGroupEmojiPackPayload.fromJson(resp);
    if (payload == null) {
      throw const ApiException(0, '群表情包响应格式不合法');
    }
    return payload;
  }

  /// `POST /emoji/groups/<conv_id>/pack/items/` —— 加入群表情
  /// （web addGroupEmojiItem(convId, mediaId, tag = "")；media 需已按 kind=emoji 上传）。
  ///
  /// 入参口径与 web 逐字一致：tag 恒发（默认空串），media_id 恒发。
  static Future<AylaEmojiItem> addGroupEmojiItem(
    String convId,
    String mediaId, {
    String tag = '',
  }) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/emoji/groups/${Uri.encodeComponent(convId)}/pack/items/',
      body: <String, dynamic>{'media_id': mediaId, 'tag': tag},
    );
    final AylaEmojiItem? item = AylaEmojiItem.fromJson(resp);
    if (item == null) throw const ApiException(0, '表情项响应格式不合法');
    return item;
  }

  /// `DELETE /emoji/groups/<conv_id>/pack/items/<id>/` —— 删除群表情
  /// （后端 views.py:305-327，成功 **204 无正文**）。
  static Future<void> deleteGroupEmojiItem(String convId, String itemId) async {
    await DioClient.instance.delete<dynamic>(
      '/emoji/groups/${Uri.encodeComponent(convId)}/pack/items/'
      '${Uri.encodeComponent(itemId)}/',
    );
  }

  /// 摘要加载的**空态收敛档**：404 ⇒ [AylaGroupEmojiPackLoad.missing]（不是错误）。
  ///
  /// 两处调用点（群聊面板 / 群详情开关）共用，保证「包未创建」的解释只有一份
  /// （web EmojiPackPanel.tsx:75-80 与 GroupInfo.tsx:232-240 是同一分支的两次抄写）。
  static Future<AylaGroupEmojiPackLoad> loadGroupEmojiPackSummary(
    String convId,
  ) async {
    try {
      return AylaGroupEmojiPackLoad(
        payload: await getGroupEmojiPackSummary(convId),
      );
    } on AylaEmojiPackMissingException {
      return const AylaGroupEmojiPackLoad(missing: true);
    } on ApiException catch (e) {
      return AylaGroupEmojiPackLoad(error: e.message);
    } catch (e) {
      return AylaGroupEmojiPackLoad(error: '$e');
    }
  }
}
