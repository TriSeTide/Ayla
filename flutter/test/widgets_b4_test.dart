import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/privacy_sheet.dart';
import '../lib/widgets/profile_and_filters.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  group('DirectoryLoadMore（tsx 行为）', () {
    testWidgets('error != null → 完全不渲染（外层负责）', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        AylaDirectoryLoadMore(
          loading: false, error: '网络错误', hasMore: true, invalidated: false,
          loadMore: () async {}, refresh: () async {},
        ),
      ));
      await tester.pump();
      expect(find.text('加载更多'), findsNothing);
      expect(find.text('网络错误'), findsNothing);
    });

    testWidgets('hasMore → 「加载更多」可点', (WidgetTester tester) async {
      int called = 0;
      await tester.pumpWidget(previewTheme(
        AylaDirectoryLoadMore(
          loading: false, error: null, hasMore: true, invalidated: false,
          loadMore: () async => called++, refresh: () async {},
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      expect(called, 1);
    });

    testWidgets('loading → 三点，无按钮', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        AylaDirectoryLoadMore(
          loading: true, error: null, hasMore: true, invalidated: false,
          loadMore: () async {}, refresh: () async {},
        ),
      ));
      await tester.pump();
      expect(find.text('加载更多'), findsNothing);
      expect(find.byType(PaginationLoadingDots), findsOneWidget);
    });

    testWidgets('invalidated → 自动 refresh（不打扰用户）', (WidgetTester tester) async {
      int refreshed = 0;
      await tester.pumpWidget(previewTheme(
        AylaDirectoryLoadMore(
          loading: false, error: null, hasMore: true, invalidated: true,
          loadMore: () async {}, refresh: () async => refreshed++,
        ),
      ));
      await tester.pump(); // 触发 post-frame
      await tester.pump();
      expect(refreshed, 1, reason: 'invalidated 应自动 refresh');
      expect(find.byType(PaginationLoadingDots), findsOneWidget);
    });

    testWidgets('紧凑模式（retainCompletedSpace=false）+ 到底 → 不渲染',
        (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        AylaDirectoryLoadMore(
          loading: false, error: null, hasMore: false, invalidated: false,
          retainCompletedSpace: false,
          loadMore: () async {}, refresh: () async {},
        ),
      ));
      await tester.pump();
      expect(find.byType(StablePaginationFooter), findsNothing,
          reason: '紧凑侧栏不保留空页脚');
    });
  });

  group('HistoryControls', () {
    testWidgets('hasMore + hasNewer → 两个按钮', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        AylaHistoryControls(
          loading: false, error: null, hasMore: true, hasNewer: true,
          loadOlder: () async {}, returnLatest: () async {}, retry: () async {},
        ),
      ));
      await tester.pump();
      expect(find.text('加载更早记录'), findsOneWidget);
      expect(find.text('返回最新消息'), findsOneWidget);
    });

    testWidgets('error → 文案 + 重试可点', (WidgetTester tester) async {
      int retried = 0;
      await tester.pumpWidget(previewTheme(
        AylaHistoryControls(
          loading: false, error: '加载历史失败', hasMore: false, hasNewer: false,
          loadOlder: () async {}, returnLatest: () async {},
          retry: () async => retried++,
        ),
      ));
      await tester.pump();
      expect(find.text('加载历史失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retried, 1);
    });

    testWidgets('loading → 三点 + 「正在加载历史」', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        AylaHistoryControls(
          loading: true, error: null, hasMore: true, hasNewer: true,
          loadOlder: () async {}, returnLatest: () async {}, retry: () async {},
        ),
      ));
      await tester.pump();
      // 三点本体（PaginationLoadingDots 带 aria-label「正在加载历史」）
      expect(find.byType(PaginationLoadingDots), findsOneWidget);
    });
  });

  group('FavoriteButton（tsx 三态 + aria）', () {
    testWidgets('未收藏 → 「收藏」，点击回调 true', (WidgetTester tester) async {
      bool? got;
      await tester.pumpWidget(previewTheme(
        AylaFavoriteButton(
          state: FavoriteState.notFavorited, onToggle: (v) => got = v),
      ));
      await tester.pump();
      expect(find.text('收藏'), findsOneWidget);
      await tester.tap(find.text('收藏'));
      await tester.pump();
      expect(got, isTrue);
    });

    testWidgets('已收藏 → 「已收藏」，点击回调 false（取消）', (WidgetTester tester) async {
      bool? got;
      await tester.pumpWidget(previewTheme(
        AylaFavoriteButton(state: FavoriteState.favorited, onToggle: (v) => got = v),
      ));
      await tester.pump();
      expect(find.text('已收藏'), findsOneWidget);
      await tester.tap(find.text('已收藏'));
      await tester.pump();
      expect(got, isFalse);
    });

    testWidgets('加载中（unknown 且无 error）→ disabled，点击无效',
        (WidgetTester tester) async {
      // tsx 69：`disabled={busy || state.loading || (unknown && !state.error)}`
      int retried = 0;
      bool? toggled;
      await tester.pumpWidget(previewTheme(
        AylaFavoriteButton(
          state: FavoriteState.unknown,
          onRetryStatus: () => retried++,
          onToggle: (v) => toggled = v,
        ),
      ));
      await tester.pump();
      expect(find.text('加载中…'), findsOneWidget);
      await tester.tap(find.text('加载中…'));
      await tester.pump();
      expect(retried, 0, reason: '加载中不可点');
      expect(toggled, isNull);
    });

    testWidgets('error 态 → **可点**且走「重试拉取状态」（tsx 35–38/69）',
        (WidgetTester tester) async {
      int retried = 0;
      bool? toggled;
      await tester.pumpWidget(previewTheme(
        AylaFavoriteButton(
          state: FavoriteState.error,
          onRetryStatus: () => retried++,
          onToggle: (v) => toggled = v,
        ),
      ));
      await tester.pump();
      expect(find.text('重试收藏状态'), findsOneWidget);
      await tester.tap(find.text('重试收藏状态'));
      await tester.pump();
      expect(retried, 1, reason: 'error 态不禁用 → 点击重试拉取');
      expect(toggled, isNull, reason: '重试不是收藏');
    });

    testWidgets('compact → 无文字、图标 16', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        AylaFavoriteButton(state: FavoriteState.favorited, compact: true, onToggle: (_) {}),
      ));
      await tester.pump();
      expect(find.text('已收藏'), findsNothing);
    });
  });

  group('VisibilitySelector（互斥 + 独立 + 锁定）', () {
    testWidgets('勾选公开 → 好友被取消（互斥）', (WidgetTester tester) async {
      VisibilitySelection? out;
      await tester.pumpWidget(previewTheme(
        AylaVisibilitySelector(
          value: const VisibilitySelection(friends: true), // 先选好友
          onChange: (v) => out = v,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('公开'));
      await tester.pump();
      expect(out, isNotNull);
      expect(out!.isPublic, isTrue);
      expect(out!.friends, isFalse, reason: '公开与好友互斥');
    });

    testWidgets('勾选好友 → 公开被取消（互斥）', (WidgetTester tester) async {
      VisibilitySelection? out;
      await tester.pumpWidget(previewTheme(
        AylaVisibilitySelector(
          value: const VisibilitySelection(isPublic: true),
          onChange: (v) => out = v,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('好友可见'));
      await tester.pump();
      expect(out!.friends, isTrue);
      expect(out!.isPublic, isFalse);
    });

    testWidgets('群可见独立：切换 group 不影响 public/friends', (WidgetTester tester) async {
      VisibilitySelection? out;
      await tester.pumpWidget(previewTheme(
        AylaVisibilitySelector(
          value: const VisibilitySelection(isPublic: true),
          onChange: (v) => out = v,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('指定群可见'));
      await tester.pump();
      expect(out!.group, isTrue);
      expect(out!.isPublic, isTrue, reason: '群与公开可叠加');
    });

    testWidgets('lockGroup → 大类不可取消（点击无效）', (WidgetTester tester) async {
      VisibilitySelection? out;
      await tester.pumpWidget(previewTheme(
        AylaVisibilitySelector(
          value: const VisibilitySelection(group: true),
          lockGroup: true,
          onChange: (v) => out = v,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('指定群可见'));
      await tester.pump();
      expect(out, isNull, reason: '锁定大类点击不应触发变更');
    });

    testWidgets('取消群可见 → 清空已选群', (WidgetTester tester) async {
      List<String>? cleared;
      await tester.pumpWidget(previewTheme(
        AylaVisibilitySelector(
          value: const VisibilitySelection(group: true),
          selectedGroupIds: const <String>['g1', 'g2'],
          onSelectedGroupIdsChange: (ids) => cleared = ids,
          onChange: (_) {},
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('指定群可见'));
      await tester.pump();
      expect(cleared, isEmpty, reason: '取消勾选清空已选群');
    });
  });

  group('PrivacySheet（状态机 + 校验，tsx 逐条）', () {
    testWidgets('menu：两项入口 + 提示文案', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () {}, boundEmail: 'ayla@example.com'),
      ));
      await tester.pump();
      expect(find.text('隐私设置'), findsOneWidget);
      expect(find.text('变更需要通过绑定邮箱验证'), findsOneWidget);
      expect(find.text('邮箱换绑'), findsOneWidget);
      expect(find.text('更改密码'), findsOneWidget);
      expect(find.text('当前：ayla@example.com'), findsOneWidget);
    });

    testWidgets('未绑定邮箱 → menu 显示「当前未绑定邮箱」', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () {}, boundEmail: ''),
      ));
      await tester.pump();
      expect(find.text('当前未绑定邮箱'), findsOneWidget);
    });

    testWidgets('改密：验证码非 6 位 → 报错「请输入 6 位数字验证码」',
        (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () {}, boundEmail: 'a@b.com'),
      ));
      await tester.pump();
      await tester.tap(find.text('更改密码'));
      await tester.pump();
      // 直接提交（code 为空）
      await tester.tap(find.text('确认修改'));
      await tester.pump();
      expect(find.text('请输入 6 位数字验证码'), findsOneWidget);
    });

    testWidgets('改密：密码 < 8 位 → 报错「新密码至少 8 位」',
        (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () {}, boundEmail: 'a@b.com'),
      ));
      await tester.pump();
      await tester.tap(find.text('更改密码'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, '123456'); // code
      await tester.pump();
      await tester.tap(find.text('确认修改'));
      await tester.pump();
      expect(find.text('新密码至少 8 位'), findsOneWidget);
    });

    testWidgets('换绑：已绑定 → 进 step1', (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () {}, boundEmail: 'a@b.com'),
      ));
      await tester.pump();
      await tester.tap(find.text('邮箱换绑'));
      await tester.pump();
      expect(find.textContaining('第一步：验证当前邮箱'), findsOneWidget);
    });

    testWidgets('换绑：未绑定 → 直接 step2（跳过 step1）',
        (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () {}, boundEmail: ''),
      ));
      await tester.pump();
      await tester.tap(find.text('邮箱换绑'));
      await tester.pump();
      expect(find.text('第二步：验证新邮箱'), findsOneWidget,
          reason: '未绑定邮箱 → setEmailStep(2) 跳过第一步');
      expect(find.textContaining('第一步'), findsNothing);
    });

    testWidgets('换绑 step1：「下一步」在验证码 6 位前禁用',
        (WidgetTester tester) async {
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () {}, boundEmail: 'a@b.com'),
      ));
      await tester.pump();
      await tester.tap(find.text('邮箱换绑'));
      await tester.pump();
      // 未填 → 点击下一步应无效（仍停在 step1）
      await tester.tap(find.text('下一步'));
      await tester.pump();
      expect(find.textContaining('第一步'), findsOneWidget);
      // 填 6 位 → 可进入 step2
      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.pump();
      await tester.tap(find.text('下一步'));
      await tester.pump();
      expect(find.text('第二步：验证新邮箱'), findsOneWidget);
    });

    testWidgets('ESC 关闭（tsx 全局 keydown）', (WidgetTester tester) async {
      int closed = 0;
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () => closed++),
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('点遮罩关闭', (WidgetTester tester) async {
      int closed = 0;
      await tester.pumpWidget(previewTheme(
        PrivacySheet(onClose: () => closed++),
      ));
      await tester.pump();
      // 遮罩铺满；点左上角（卡片外）
      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('发码：未填新邮箱时按钮禁用（step2）', (WidgetTester tester) async {
      int sent = 0;
      await tester.pumpWidget(previewTheme(
        PrivacySheet(
          onClose: () {}, boundEmail: '',
          sendEmailCode: (String e) async => sent++,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('邮箱换绑'));
      await tester.pump();
      expect(find.text('第二步：验证新邮箱'), findsOneWidget);
      await tester.tap(find.text('发送验证码'));
      await tester.pump();
      expect(sent, 0, reason: '新邮箱为空 → 发码禁用');
    });
  });
}
