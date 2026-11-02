/// **安装位置不可用时的阻断页**（2026-11-02）。
///
/// 用户要求「全部改到 `<exe目录>\data\`，不允许任何 C 盘降级回退」。
/// 当 Ayla 被放进 `Program Files` 等受保护目录时，程序目录不可写 ⇒ 无处落盘。
/// 本页是**唯一**的应对方式：不静默降级、不带病启动，而是明确告知 + 给一键出路。
///
/// ## 为什么是一整页而不是 SnackBar
/// 此时**连偏好都存不下**（主题、草稿、登录态全部失效），任何「继续用」的入口
/// 都只会制造后续的散装故障。必须在写任何业务数据之前拦住。
///
/// ## 视觉
/// 刻意极简（不用玻璃/极光组件）：本页在 `runApp` 最早路径上，此时主题、
/// Provider、字体缩放都还没装配；用 Material 默认件最稳，也最不容易因为
/// 某个组件依赖未就绪而二次崩溃。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/storage/ayla_storage_diagnosis.dart';
import '../../core/storage/ayla_storage_paths.dart';

class AylaStorageBlockedApp extends StatefulWidget {
  const AylaStorageBlockedApp({super.key, required this.diagnosis});

  final AylaStorageDiagnosis diagnosis;

  @override
  State<AylaStorageBlockedApp> createState() => _AylaStorageBlockedAppState();
}

class _AylaStorageBlockedAppState extends State<AylaStorageBlockedApp> {
  bool _busy = false;
  String? _error;
  String? _donePath;

  Future<void> _relocate() async {
    final String? target = widget.diagnosis.relocateTarget;
    if (target == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final String newExe = await aylaRelocateInstallation(target);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _donePath = newExe;
      });
    } on AylaStorageException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaStorageDiagnosis d = widget.diagnosis;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF6F8FC),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'Ayla 无法启动：安装位置不可写',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF465B92),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    d.reason ?? '程序目录不可写',
                    style: const TextStyle(fontSize: 15, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    '期望的数据目录：\n${d.dataRoot}',
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: Color(0xFF7E95BD),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4E5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFFD9A0)),
                    ),
                    child: const Text(
                      '为什么不能自动换地方存：\n'
                      'Ayla 的所有本地数据（账号凭据、聊天草稿、媒体缓存、更新包）'
                      '都固定存放在程序目录下的 data/ 里，这是你明确要求的'
                      '「不写 C 盘、不允许任何降级回退」。程序目录不可写时，'
                      '就没有合法的落盘位置了。',
                      style: TextStyle(fontSize: 13, height: 1.7),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_donePath != null) ...<Widget>[
                    const Text(
                      '✅ 已复制到新位置。请关闭本窗口，运行：',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _donePath!,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF465B92)),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '原目录没有删除，确认新位置能正常使用后可自行删除。',
                      style: TextStyle(fontSize: 12, color: Color(0xFF7E95BD)),
                    ),
                  ] else ...<Widget>[
                    const Text(
                      '推荐做法（按推荐度）',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (d.relocateTarget != null)
                      _Option(
                        index: 1,
                        title: '一键搬到用户目录（推荐）',
                        detail: d.relocateTarget!,
                        trailing: FilledButton(
                          onPressed: _busy ? null : _relocate,
                          child: Text(_busy ? '复制中…' : '一键搬迁'),
                        ),
                      ),
                    const _Option(
                      index: 2,
                      title: '自己把整个 Ayla 文件夹拖到可写位置',
                      detail: '例如 D:\\Ayla 或 E:\\Ayla，然后运行里面的 ayla_flutter.exe。'
                          '不要放在 Program Files。',
                    ),
                    const _Option(
                      index: 3,
                      title: '以管理员身份运行（不推荐）',
                      detail: '能写 Program Files，但每次自更新仍会要求提权，且权限面更大。',
                    ),
                  ],
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      '搬迁失败：$_error',
                      style: const TextStyle(fontSize: 13, color: Color(0xFFB3261E)),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    '当前平台：${Platform.operatingSystem} · '
                    '可执行文件：${Platform.resolvedExecutable}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9AA8BF)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.index,
    required this.title,
    required this.detail,
    this.trailing,
  });

  final int index;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 26,
            child: Text(
              '$index.',
              style: const TextStyle(fontSize: 14, color: Color(0xFF7E95BD)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  detail,
                  style: const TextStyle(fontSize: 12, height: 1.6, color: Color(0xFF7E95BD)),
                ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}
