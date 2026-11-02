/// **Windows 上自管的 DPAPI 加密凭据文件**（2026-11-02）。
///
/// ## 为什么不用 `flutter_secure_storage`
/// 该插件在 Windows 上的落点是「应用支持目录 /flutter_secure_storage.dat」
/// （`flutter_secure_storage_windows-4.2.2/lib/src/flutter_secure_storage_windows_ffi.dart:257`
/// 文件名常量、`:275-284` 目录解析），而 path_provider 的应用支持目录恒为
/// `%APPDATA%\Roaming\com.ayla\ayla_flutter` —— **插件没有提供配置目录的入口**。
/// 既然用户要求「不落 C 盘、且不允许 C 盘回退」，Windows 分支必须自管一个文件。
///
/// ## 与插件的等价性
/// 加密算法与插件完全一致：整份 JSON → UTF-8 → `CryptProtectData`（DPAPI，当前用户作用域）
/// → 写文件；读取时 `CryptUnprotectData` 还原。密钥由 Windows 按当前用户托管，
/// 文件拷到别的账户无法解密 —— 与插件同一安全模型。
///
/// ## 非 Windows
/// Android 用 Keystore + SharedPreferences、iOS 用 Keychain（都是平台安全存储，不是「用户目录」），
/// 继续走 `flutter_secure_storage`。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ayla_storage_paths.dart';

/// 凭据文件名（与插件同名，便于迁移时直接搬过来）。
const String kAylaSecureStoreFileName = 'flutter_secure_storage.dat';

/// 安全存储的最小契约（测试注入内存实现）。
abstract interface class AylaSecureStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// 生产实现：Windows 走自管 DPAPI 文件，其它平台走 `flutter_secure_storage`。
class AylaFlutterSecureStore implements AylaSecureStore {
  const AylaFlutterSecureStore([this._fallback = const FlutterSecureStorage()]);

  final FlutterSecureStorage _fallback;

  bool get _useOwnDpapiFile => Platform.isWindows;

  @override
  Future<String?> read(String key) async {
    if (!_useOwnDpapiFile) return _fallback.read(key: key);
    final Map<String, String> data = await _readAll();
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (!_useOwnDpapiFile) {
      await _fallback.write(key: key, value: value);
      return;
    }
    final Map<String, String> data = await _readAll();
    data[key] = value;
    await _writeAll(data);
  }

  @override
  Future<void> delete(String key) async {
    if (!_useOwnDpapiFile) {
      await _fallback.delete(key: key);
      return;
    }
    final Map<String, String> data = await _readAll();
    if (data.remove(key) == null) return;
    await _writeAll(data);
  }

  Future<File> _file() async {
    final Directory profile = await aylaProfileDirectory();
    return File(
      '${profile.path}${Platform.pathSeparator}$kAylaSecureStoreFileName',
    );
  }

  /// 读取并解密整份文件（不存在/损坏 ⇒ 空表，绝不抛）。
  Future<Map<String, String>> _readAll() async {
    final File file = await _file();
    if (!file.existsSync()) return <String, String>{};
    try {
      final Uint8List encrypted = await file.readAsBytes();
      if (encrypted.isEmpty) return <String, String>{};
      final String plain = aylaDpapiUnprotect(encrypted);
      final Object? decoded = jsonDecode(plain);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final MapEntry<Object?, Object?> e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key! as String: e.value! as String,
      };
    } catch (error) {
      debugPrint('[AylaAuth] 凭据文件读取失败（按未保存处理）：$error');
      return <String, String>{};
    }
  }

  Future<void> _writeAll(Map<String, String> data) async {
    final File file = await _file();
    final Uint8List encrypted =
        aylaDpapiProtect(utf8.encode(jsonEncode(data)));
    await file.writeAsBytes(encrypted, flush: true);
  }
}

// ---------------------------------------------------------------------------
// DPAPI 绑定（与 flutter_secure_storage_windows 4.2.2 同一组 API）
// ---------------------------------------------------------------------------

/// `CRYPT_INTEGER_BLOB`（`DATA_BLOB`）：`{DWORD cbData; BYTE* pbData;}`。
final class _CryptIntegerBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataNative = Int32 Function(
  Pointer<_CryptIntegerBlob> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<_CryptIntegerBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<_CryptIntegerBlob> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_CryptIntegerBlob> pDataOut,
);
typedef _CryptProtectDataDart = int Function(
  Pointer<_CryptIntegerBlob> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<_CryptIntegerBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<_CryptIntegerBlob> pPromptStruct,
  int dwFlags,
  Pointer<_CryptIntegerBlob> pDataOut,
);

typedef _CryptUnprotectDataNative = Int32 Function(
  Pointer<_CryptIntegerBlob> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<_CryptIntegerBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<_CryptIntegerBlob> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_CryptIntegerBlob> pDataOut,
);
typedef _CryptUnprotectDataDart = int Function(
  Pointer<_CryptIntegerBlob> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<_CryptIntegerBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<_CryptIntegerBlob> pPromptStruct,
  int dwFlags,
  Pointer<_CryptIntegerBlob> pDataOut,
);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> hMem);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> hMem);

DynamicLibrary? _crypt32;
DynamicLibrary? _kernel32;

DynamicLibrary get _crypt32Lib => _crypt32 ??= DynamicLibrary.open('crypt32.dll');
DynamicLibrary get _kernel32Lib =>
    _kernel32 ??= DynamicLibrary.open('kernel32.dll');

/// 用 DPAPI（当前用户作用域）加密任意字节。失败抛 [StateError]。
Uint8List aylaDpapiProtect(List<int> plain) {
  final _CryptProtectDataDart protect = _crypt32Lib
      .lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
        'CryptProtectData',
      );
  final _LocalFreeDart localFree = _kernel32Lib
      .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  return using<Uint8List>((Arena alloc) {
    final Pointer<Uint8> input = alloc<Uint8>(plain.isEmpty ? 1 : plain.length);
    if (plain.isNotEmpty) {
      input.asTypedList(plain.length).setAll(0, plain);
    }
    final Pointer<_CryptIntegerBlob> blobIn = alloc<_CryptIntegerBlob>();
    blobIn.ref.cbData = plain.length;
    blobIn.ref.pbData = input;

    final Pointer<_CryptIntegerBlob> blobOut = alloc<_CryptIntegerBlob>();
    final int ok = protect(
      blobIn,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0,
      blobOut,
    );
    if (ok == 0) {
      throw StateError('CryptProtectData 失败（错误码 $ok）');
    }
    try {
      if (blobOut.ref.pbData == nullptr) {
        throw StateError('CryptProtectData 返回空指针');
      }
      return Uint8List.fromList(
        blobOut.ref.pbData.asTypedList(blobOut.ref.cbData),
      );
    } finally {
      if (blobOut.ref.pbData != nullptr) {
        localFree(blobOut.ref.pbData.cast<Void>());
      }
    }
  });
}

/// 用 DPAPI（当前用户作用域）解密。失败抛 [StateError]。
String aylaDpapiUnprotect(Uint8List encrypted) {
  final _CryptUnprotectDataDart unprotect = _crypt32Lib
      .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
        'CryptUnprotectData',
      );
  final _LocalFreeDart localFree = _kernel32Lib
      .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  return using<String>((Arena alloc) {
    final Pointer<Uint8> input =
        alloc<Uint8>(encrypted.isEmpty ? 1 : encrypted.length);
    if (encrypted.isNotEmpty) {
      input.asTypedList(encrypted.length).setAll(0, encrypted);
    }
    final Pointer<_CryptIntegerBlob> blobIn = alloc<_CryptIntegerBlob>();
    blobIn.ref.cbData = encrypted.length;
    blobIn.ref.pbData = input;

    final Pointer<_CryptIntegerBlob> blobOut = alloc<_CryptIntegerBlob>();
    final int ok = unprotect(
      blobIn,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0,
      blobOut,
    );
    if (ok == 0) {
      throw StateError('CryptUnprotectData 失败（错误码 $ok）');
    }
    try {
      if (blobOut.ref.pbData == nullptr) {
        throw StateError('CryptUnprotectData 返回空指针');
      }
      return utf8.decode(
        blobOut.ref.pbData.asTypedList(blobOut.ref.cbData),
        allowMalformed: true,
      );
    } finally {
      if (blobOut.ref.pbData != nullptr) {
        localFree(blobOut.ref.pbData.cast<Void>());
      }
    }
  });
}
