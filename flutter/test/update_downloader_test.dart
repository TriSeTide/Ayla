/// 下载/校验/文件名净化的契约。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/update/update_api.dart';
import '../lib/core/update/update_downloader.dart';

void main() {
  group('sanitizeUpdateFileName', () {
    test('取最后一段并去掉路径分隔符', () {
      expect(sanitizeUpdateFileName('a/b/c.zip'), 'c.zip');
      expect(sanitizeUpdateFileName(r'C:\temp\ayla.zip'), 'ayla.zip');
    });

    test('空/点号回落固定名', () {
      expect(sanitizeUpdateFileName(''), 'ayla-update.bin');
      expect(sanitizeUpdateFileName('..'), 'ayla-update.bin');
      expect(sanitizeUpdateFileName('dir/'), 'dir');
    });

    test('去掉 Windows 非法字符与控制字符', () {
      expect(sanitizeUpdateFileName('a:b*c?.zip'), 'a_b_c_.zip');
      expect(sanitizeUpdateFileName(r'C:\dir\file?.zip'), 'file_.zip');
      expect(sanitizeUpdateFileName('a\u0001b.zip'), 'a_b.zip');
    });
  });

  group('sha256OfFile', () {
    test('与已知摘要一致（"abc" → ba7816bf…）', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'ayla_sha_test',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}${Platform.pathSeparator}abc.bin');
      await file.writeAsBytes(<int>[0x61, 0x62, 0x63]);
      expect(
        await sha256OfFile(file),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('下载失败语义', () {
    test('清单大小非法时立即拒绝（不触网）', () async {
      final AylaUpdateDownload download = AylaUpdateDownload(
        kind: 'zip',
        url: 'http://127.0.0.1:1/never',
        fileName: 'x.zip',
        size: 0,
        sha256: 'a' * 64,
      );
      expect(
        () => AylaUpdateDownloader().download(download),
        throwsA(isA<AylaUpdateDownloadException>()),
      );
    });
  });
}
