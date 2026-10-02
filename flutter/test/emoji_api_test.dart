/// 表情包域 API 端到端回归锁 —— 对照 web `api/emoji.ts:33-82` +
/// `EmojiPackPanel.tsx:67-81` + `GroupInfo.tsx:222-242`。
///
/// ## 口径（硬要求）
/// 断言**真实到达服务端的 method / path / query / body**，不是函数返回值、
/// 不是纯函数（与 `chat_send_subgroup_test.dart` 同款范式：真实回环 HTTP server）。
///
/// 覆盖：
/// ① 五个方法的 method + path + query（含转义）·
/// ② 分页参数 `pagination=cursor & limit=30 & cursor`（web mediaPagination.ts:17-19）·
/// ③ body 契约（`{allow_member_upload}` / `{media_id, tag}`）·
/// ④ 404 group_pack_not_found ⇒ 空态（不抛致命错误）·
/// ⑤ 其它 404（群不存在）与 403 ⇒ 仍按真实错误上报（不被空态吞）·
/// ⑥ 上传 kind：群表情必须以 `kind=emoji` 走 `/media/uploads`
///   （web tsx:113 / 后端 apps/emoji/services.py:118）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/emoji_api.dart';
import '../lib/core/media/media_actions.dart';
import '../lib/core/media/media_picker.dart'
    show
        AylaFilePickerBackend,
        AylaMediaPicker,
        AylaPickedFile,
        AylaPickerBackend,
        AylaPickKind;
import '../lib/core/media/media_upload.dart' show AylaMediaUploader;
import '../lib/core/models/post.dart' show AylaMediaPickResult;
import '../lib/core/net/dio_client.dart';

/// 无令牌占位（本文件只验 method/path/query/body，不关心鉴权头）。
class _NoToken implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

/// 选图替身：给一张合法 png 头（本地校验只看类型/大小，不解析像素）。
class _StubPicker implements AylaPickerBackend {
  @override
  Future<List<AylaPickedFile>> pick({
    required AylaPickKind kind,
    bool multiple = false,
  }) async =>
      <AylaPickedFile>[
        AylaPickedFile(
          name: 'emoji.png',
          size: 16,
          mimeType: 'image/png',
          path: null,
          readBytes: () async => Uint8List.fromList(<int>[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
          ]),
        ),
      ];
}

/// 一次到达的请求（method / uri / body，全部原样记录）。
class _Hit {
  _Hit(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final Map<String, dynamic>? body;
}

/// 回环服务端：按路径给响应，并把请求记进 [hits]。
class _Server {
  final List<_Hit> hits = <_Hit>[];

  /// 下一次 GET pack 摘要的响应（默认 200 已建包）。
  int summaryStatus = 200;
  Map<String, dynamic> summaryBody = <String, dynamic>{
    'pack': <String, dynamic>{'id': '77', 'name': '群表情', 'item_count': 3},
    'allow_member_upload': true,
    'can_upload': true,
    'can_delete': false,
  };

  /// 下一次 GET items 的响应。
  Map<String, dynamic> itemsBody = <String, dynamic>{
    'results': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': '5',
        'tag': '',
        'media': <String, dynamic>{'media_id': 'm5', 'kind': 'emoji'},
      },
    ],
    'next_cursor': 'c2',
    'has_more': true,
    'total': 9,
  };

  /// 下一次 DELETE 的状态码（后端成功 = 204 无正文）。
  int deleteStatus = 204;

  /// 下一次 POST items 的状态码（后端创建 = 201）。
  int addStatus = 201;

  /// 收到的 POST /media/uploads 请求体（kind 契约判据）。
  final List<Map<String, dynamic>> mediaUploads = <Map<String, dynamic>>[];

  Uri get lastUri => hits.isEmpty ? Uri() : hits.last.uri;

  Future<void> handle(HttpRequest request) async {
    // ⚠️ 不能无条件按 UTF-8 解 body：二进制上传（PUT /media/uploads/<id>）是**原始 png 字节**
    // ⇒ `utf8.decoder` 抛 FormatException（2026-10-02 实测）。只有 JSON 端点才解码。
    final bool isBinary = request.method == 'PUT';
    final List<int> rawBytes =
        await request.fold<List<int>>(<int>[], (List<int> acc, List<int> c) => acc..addAll(c));
    final Map<String, dynamic>? body = isBinary || rawBytes.isEmpty
        ? null
        : jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
    hits.add(_Hit(request.method, request.uri, body));

    final String path = request.uri.path;
    request.response.headers.contentType = ContentType.json;
    if (path.endsWith('/media/uploads') && request.method == 'POST') {
      mediaUploads.add(body ?? <String, dynamic>{});
      request.response.statusCode = 200;
      request.response.write(jsonEncode(<String, dynamic>{
        'upload_id': 'u1',
        'kind': body?['kind'],
        'max_bytes': 1048576,
        'expires_at': '2026-12-31T00:00:00Z',
        'presigned_url': '',
      }));
    } else if (path.contains('/media/uploads/') && path.contains(':complete')) {
      request.response.statusCode = 200;
      request.response.write(jsonEncode(<String, dynamic>{
        'media_id': 'm1',
        'descriptor': <String, dynamic>{
          'media_id': 'm1',
          'kind': 'emoji',
          'mime_type': 'image/png',
          'size': 16,
          'status': 'ready',
        },
      }));
    } else if (path.contains('/media/uploads/') && request.method == 'PUT') {
      request.response.statusCode = 200;
      request.response.write('{}');
    } else if (path.endsWith('/pack/items/') && request.method == 'POST') {
      request.response.statusCode = addStatus;
      request.response.write(jsonEncode(<String, dynamic>{
        'id': '9',
        'tag': '',
        'media': <String, dynamic>{'media_id': 'm9', 'kind': 'emoji'},
      }));
    } else if (path.endsWith('/pack/items/') && request.method == 'GET') {
      request.response.statusCode = 200;
      request.response.write(jsonEncode(itemsBody));
    } else if (path.contains('/pack/items/') && request.method == 'DELETE') {
      request.response.statusCode = deleteStatus;
      if (deleteStatus != 204) {
        request.response
            .write(jsonEncode(<String, dynamic>{'detail': '表情项不存在'}));
      }
    } else if (path.endsWith('/pack/') && request.method == 'GET') {
      request.response.statusCode = summaryStatus;
      request.response.write(jsonEncode(summaryBody));
    } else if (path.endsWith('/pack/') && request.method == 'PATCH') {
      request.response.statusCode = 200;
      request.response.write(jsonEncode(<String, dynamic>{
        'pack': <String, dynamic>{'id': '77', 'name': '群表情', 'item_count': 3},
        'allow_member_upload':
            (body ?? <String, dynamic>{})['allow_member_upload'] == true,
        'can_upload': true,
        'can_delete': true,
      }));
    } else {
      request.response.statusCode = 200;
      request.response.write('{}');
    }
    await request.response.close();
  }
}

void main() {
  // 真实回环 HTTP：不要初始化 widget binding（它会把进程内 HTTP 全换成 400 mock）。
  HttpOverrides.global = null;

  late _Server srv;
  late HttpServer server;

  setUpAll(() async {
    srv = _Server();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen(srv.handle);
    // ⚠️ 顺序固定：先设 override（dio 的 baseUrl 只在首次 init 时构造），再 init。
    DioClient.instance.debugBaseUrlOverride = 'http://127.0.0.1:${server.port}';
    DioClient.instance.init(tokenStore: _NoToken(), onSessionExpired: () {});
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    srv.hits.clear();
    srv.mediaUploads.clear();
    srv.summaryStatus = 200;
    srv.deleteStatus = 204;
    srv.addStatus = 201;
    srv.summaryBody = <String, dynamic>{
      'pack': <String, dynamic>{'id': '77', 'name': '群表情', 'item_count': 3},
      'allow_member_upload': true,
      'can_upload': true,
      'can_delete': false,
    };
  });

  group('method / path / query（web api/emoji.ts:33-82）', () {
    test('getGroupEmojiPackSummary ⇒ GET /api/v1/emoji/groups/<id>/pack/?summary=1',
        () async {
      final AylaGroupEmojiPackPayload p =
          await AylaEmojiApi.getGroupEmojiPackSummary('43');
      expect(srv.lastUri.path, '/api/v1/emoji/groups/43/pack/',
          reason: 'api/emoji.ts:34 的路径逐字（kApiPrefix = /api/v1）');
      expect(srv.lastUri.queryParameters['summary'], '1',
          reason: 'api/emoji.ts:34 的 ?summary=1（摘要档不带 items）');
      expect(srv.hits.single.method, 'GET');
      expect(p.packId, '77');
      expect(p.allowMemberUpload, isTrue);
      expect(p.canUpload, isTrue);
      expect(p.canDelete, isFalse);
    });

    test('listGroupEmojiItemsPage ⇒ GET .../pack/items/?pagination=cursor&limit=30（首页）',
        () async {
      final page = await AylaEmojiApi.listGroupEmojiItemsPage('43');
      expect(srv.hits.single.method, 'GET');
      expect(srv.lastUri.path, '/api/v1/emoji/groups/43/pack/items/');
      expect(srv.lastUri.queryParameters['pagination'], 'cursor',
          reason: 'web mediaPagination.ts:17 恒发 pagination=cursor');
      expect(srv.lastUri.queryParameters['limit'], '30',
          reason: 'api/emoji.ts:38 与 EmojiPackPanel.tsx:63 的 limit: 30');
      expect(srv.lastUri.queryParameters.containsKey('cursor'), isFalse,
          reason: '首页不发 cursor（web mediaPageQuery 仅非空才 set）');
      expect(page.results.single.id, '5');
      expect(page.results.single.media!.mediaId, 'm5');
      expect(page.nextCursor, 'c2');
      expect(page.hasMore, isTrue);
      expect(page.total, 9);
    });

    test('listGroupEmojiItemsPage ⇒ 带 cursor 时 query 里有 cursor', () async {
      await AylaEmojiApi.listGroupEmojiItemsPage('43', cursor: 'c2', limit: 30);
      expect(srv.lastUri.queryParameters['cursor'], 'c2');
      expect(srv.lastUri.queryParameters['pagination'], 'cursor');
      expect(srv.lastUri.queryParameters['limit'], '30');
    });

    test(
        'setGroupEmojiUploadPolicy ⇒ PATCH .../pack/?summary=1 + body {allow_member_upload}',
        () async {
      final AylaGroupEmojiPackPayload p =
          await AylaEmojiApi.setGroupEmojiUploadPolicy('43', true);
      expect(srv.hits.single.method, 'PATCH');
      expect(srv.lastUri.path, '/api/v1/emoji/groups/43/pack/');
      expect(srv.lastUri.queryParameters['summary'], '1',
          reason: 'api/emoji.ts:63 的 ?summary=1');
      expect(srv.hits.single.body, <String, dynamic>{'allow_member_upload': true},
          reason: 'api/emoji.ts:65 的 body 只有这一个键');
      expect(p.allowMemberUpload, isTrue);
    });

    test('setGroupEmojiUploadPolicy(false) ⇒ body 里是 false（不被当缺省省略）', () async {
      await AylaEmojiApi.setGroupEmojiUploadPolicy('43', false);
      expect(srv.hits.single.body!['allow_member_upload'], isFalse);
    });

    test('addGroupEmojiItem ⇒ POST .../pack/items/ + body {media_id, tag}（tag 默认空串）',
        () async {
      await AylaEmojiApi.addGroupEmojiItem('43', 'm9');
      expect(srv.hits.single.method, 'POST');
      expect(srv.lastUri.path, '/api/v1/emoji/groups/43/pack/items/');
      expect(srv.hits.single.body, <String, dynamic>{'media_id': 'm9', 'tag': ''},
          reason: 'api/emoji.ts:70-74：addGroupEmojiItem(convId, mediaId, tag = "")');
    });

    test('addGroupEmojiItem 带 tag ⇒ tag 原样进 body', () async {
      await AylaEmojiApi.addGroupEmojiItem('43', 'm9', tag: '猫猫');
      expect(srv.hits.single.body!['tag'], '猫猫');
    });

    test('deleteGroupEmojiItem ⇒ DELETE .../pack/items/<id>/（无 body）', () async {
      await AylaEmojiApi.deleteGroupEmojiItem('43', '5');
      expect(srv.hits.single.method, 'DELETE');
      expect(srv.lastUri.path, '/api/v1/emoji/groups/43/pack/items/5/');
      expect(srv.hits.single.body, isNull);
    });

    test('convId / itemId 需要转义（web seg() = encodeURIComponent）', () async {
      await AylaEmojiApi.getGroupEmojiPackSummary('a b/c');
      expect(srv.lastUri.path, '/api/v1/emoji/groups/a%20b%2Fc/pack/');
      await AylaEmojiApi.deleteGroupEmojiItem('43', 'x/y');
      expect(srv.lastUri.path, '/api/v1/emoji/groups/43/pack/items/x%2Fy/');
    });
  });

  group('404 = 空态（web api/emoji.ts:56 + EmojiPackPanel.tsx:75-80）', () {
    test('getGroupEmojiPackSummary 遇 group_pack_not_found ⇒ AylaEmojiPackMissingException（404）',
        () async {
      srv.summaryStatus = 404;
      srv.summaryBody = <String, dynamic>{'detail': 'group_pack_not_found'};
      await expectLater(
        AylaEmojiApi.getGroupEmojiPackSummary('43'),
        throwsA(
          isA<AylaEmojiPackMissingException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', 'group_pack_not_found'),
        ),
      );
    });

    test('★ loadGroupEmojiPackSummary：404 ⇒ missing=true 且 error=null（不抛致命错误）',
        () async {
      srv.summaryStatus = 404;
      srv.summaryBody = <String, dynamic>{'detail': 'group_pack_not_found'};
      final AylaGroupEmojiPackLoad load =
          await AylaEmojiApi.loadGroupEmojiPackSummary('43');
      expect(load.missing, isTrue);
      expect(load.error, isNull);
      expect(load.payload, isNull);
      expect(load.settled, isTrue, reason: '「确认未建包」是确定状态，不是未加载');
      expect(load.allowMemberUpload, isFalse,
          reason: 'web GroupInfo.tsx:234-236：404 ⇒ allow_member_upload = false');
    });

    test('loadGroupEmojiPackSummary：200 ⇒ payload 就位、missing=false', () async {
      final AylaGroupEmojiPackLoad load =
          await AylaEmojiApi.loadGroupEmojiPackSummary('43');
      expect(load.missing, isFalse);
      expect(load.error, isNull);
      expect(load.payload!.packId, '77');
      expect(load.allowMemberUpload, isTrue);
    });

    test('★ 404「群不存在」不被空态吞掉（真错误必须上报）', () async {
      srv.summaryStatus = 404;
      srv.summaryBody = <String, dynamic>{'detail': '群不存在'};
      final AylaGroupEmojiPackLoad load =
          await AylaEmojiApi.loadGroupEmojiPackSummary('43');
      expect(load.missing, isFalse, reason: 'detail 不是 group_pack_not_found');
      expect(load.error, '群不存在');
    });

    test('★ 403 非群成员不被空态吞掉', () async {
      srv.summaryStatus = 403;
      srv.summaryBody = <String, dynamic>{'detail': '无权访问'};
      final AylaGroupEmojiPackLoad load =
          await AylaEmojiApi.loadGroupEmojiPackSummary('43');
      expect(load.missing, isFalse);
      expect(load.error, '无权访问');
    });

    test('★ 非 404 的 getGroupEmojiPackSummary 仍抛普通 ApiException（不是 missing 子类）',
        () async {
      srv.summaryStatus = 500;
      srv.summaryBody = <String, dynamic>{'detail': '服务器炸了'};
      await expectLater(
        AylaEmojiApi.getGroupEmojiPackSummary('43'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 500)
              .having((e) => e is AylaEmojiPackMissingException, 'is missing',
                  isFalse),
        ),
      );
    });
  });

  group('删除的真实状态码（后端 views.py:327 成功 = 204 无正文）', () {
    test('delete 成功 204 ⇒ 正常返回，不因空正文抛错', () async {
      await AylaEmojiApi.deleteGroupEmojiItem('43', '5');
      expect(srv.hits.single.method, 'DELETE');
    });

    test('delete 404 ⇒ 抛 ApiException(404)（删除失败是真错误，不当空态）', () async {
      srv.deleteStatus = 404;
      await expectLater(
        AylaEmojiApi.deleteGroupEmojiItem('43', '5'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
      );
    });
  });

  group('上传 kind：群表情必须 kind=emoji（web tsx:113 / 后端 services.py:118）', () {
    /// 接上上传链（**不再自建 server / 不再重复 init**：`DioClient.init` 幂等，
    /// 第二次调用不会重建 baseUrl —— 2026-10-02 实测踩过，改用 setUpAll 的主 server）。
    void wireUploader() {
      AylaMediaUploader.instance.attach(DioClient.instance);
      addTearDown(() => AylaMediaUploader.instance.detach());
      AylaMediaPicker.backend = _StubPicker();
      addTearDown(() => AylaMediaPicker.backend = const AylaFilePickerBackend());
    }

    test('★ pickEmojiImages 全链：到达服务端的 kind 是 emoji', () async {
      // 走真实链路：AylaMediaActions.pickEmojiImages → 选图替身 → uploadBytes
      // → POST /media/uploads。判据 = 服务端收到的 kind 字段。
      wireUploader();

      final AylaMediaPickResult result =
          await AylaMediaActions.pickEmojiImages(remaining: 5);
      expect(result.drafts, hasLength(1),
          reason: '▲ 上传链必须真的跑通（否则下面的 kind 断言是空的）');
      expect(srv.mediaUploads, hasLength(1));
      expect(srv.mediaUploads.single['kind'], 'emoji',
          reason: '★ 群表情必须以 kind=emoji 上传（web tsx:113 / 后端 services.py:118）');
    });

    test('对照组：pickImages 全链的 kind 是 image（证明判据能区分两档）', () async {
      wireUploader();

      final AylaMediaPickResult result =
          await AylaMediaActions.pickImages(remaining: 5);
      expect(result.drafts, hasLength(1));
      expect(srv.mediaUploads.single['kind'], 'image',
          reason: '对照组：普通图片仍是 image（两档确实不同）');
    });
  });
}
