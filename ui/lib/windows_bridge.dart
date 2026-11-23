import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

const _dashboardClass = 'ExtScreenFlutterDashboard';
const _pipeName = r'\\.\pipe\ExtScreenHostDashboard.v1';

class HostBridge {
  const HostBridge();

  Future<void> ensureRunning() async {
    final override = Platform.environment['EXTSCREEN_HOST_EXE'];
    final installed = File(
      '${File(Platform.resolvedExecutable).parent.path}\\extscreen-host.exe',
    );
    final host = override == null ? installed : File(override);
    if (!await host.exists()) return;
    await Process.start(
      host.path,
      const ['--minimized'],
      workingDirectory: host.parent.path,
      mode: ProcessStartMode.detached,
    );
  }

  Future<Map<String, dynamic>> request(String command, [Object? value]) =>
      Isolate.run(
        () => _exchange(<String, Object>{
          'command': command,
          if (value != null) 'value': value,
        }),
      );

  void hideDashboard() => _windowAction((user, window) {
    final show = user
        .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
          'ShowWindow',
        );
    show(window, 0);
  });

  void setDashboardDark(bool dark) => _windowAction((user, window) {
    final send = user
        .lookupFunction<
          IntPtr Function(IntPtr, Uint32, UintPtr, IntPtr),
          int Function(int, int, int, int)
        >('SendMessageW');
    send(window, 0x8000 + 103, dark ? 1 : 0, 0);
  });

  void _windowAction(void Function(DynamicLibrary, int) action) {
    final user = DynamicLibrary.open('user32.dll');
    final find = user
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowW');
    final className = _dashboardClass.toNativeUtf16();
    try {
      final window = find(className, nullptr);
      if (window != 0) action(user, window);
    } finally {
      calloc.free(className);
    }
  }
}

Map<String, dynamic> _exchange(Map<String, Object> request) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final create = kernel
      .lookupFunction<
        IntPtr Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  final read = kernel
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('ReadFile');
  final write = kernel
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('WriteFile');
  final close = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final pipe = _pipeName.toNativeUtf16();
  final handle = create(
    pipe,
    0xC0000000, // GENERIC_READ | GENERIC_WRITE
    0,
    nullptr,
    3, // OPEN_EXISTING
    0x00100000, // SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS
    0,
  );
  calloc.free(pipe);
  if (handle == -1) throw const OSError('ExtScreen host is not available');

  const capacity = 4096;
  final buffer = calloc<Uint8>(capacity);
  final size = calloc<Uint32>();
  try {
    final message = utf8.encode('${jsonEncode(request)}\n');
    buffer.asTypedList(message.length).setAll(0, message);
    if (write(handle, buffer, message.length, size, nullptr) == 0 ||
        size.value != message.length) {
      throw const OSError('Could not send the dashboard request');
    }
    final response = <int>[];
    while (response.length < 65536) {
      if (read(handle, buffer, capacity, size, nullptr) == 0 ||
          size.value == 0) {
        throw const OSError('ExtScreen host closed the dashboard connection');
      }
      final chunk = buffer.asTypedList(size.value);
      final newline = chunk.indexOf(10);
      if (newline >= 0) {
        response.addAll(chunk.take(newline));
        return jsonDecode(utf8.decode(response)) as Map<String, dynamic>;
      }
      response.addAll(chunk);
    }
    throw const FormatException('Dashboard response is too large');
  } finally {
    calloc.free(size);
    calloc.free(buffer);
    close(handle);
  }
}
