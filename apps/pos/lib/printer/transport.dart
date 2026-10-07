// Куда отправлять байты ESC/POS: принтер Windows (USB через драйвер, режим RAW)
// или сетевой принтер (Ethernet/Wi-Fi, порт 9100). На Android — сетевой.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sm_core/sm_core.dart' show tr;

/// Настройки принтера кассы (хранятся в printer.json).
class PrinterConfig {
  PrinterConfig({this.kind = 'none', this.name = '', this.host = '', this.port = 9100, this.paperMm = 80, this.codePage = 17, this.drawer = true});

  /// none, windows (принтер Windows по имени), network (IP:порт).
  final String kind;
  final String name;
  final String host;
  final int port;
  final int paperMm;
  final int codePage;

  /// Открывать денежный ящик при оплате наличными.
  final bool drawer;

  bool get enabled => kind != 'none';

  String get title => switch (kind) {
        'windows' => name,
        'network' => '$host:$port',
        _ => tr('не выбран', 'tanlanmagan'),
      };

  PrinterConfig copyWith({String? kind, String? name, String? host, int? port, int? paperMm, int? codePage, bool? drawer}) => PrinterConfig(
        kind: kind ?? this.kind,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        paperMm: paperMm ?? this.paperMm,
        codePage: codePage ?? this.codePage,
        drawer: drawer ?? this.drawer,
      );

  Map<String, dynamic> toJson() =>
      {'kind': kind, 'name': name, 'host': host, 'port': port, 'paper_mm': paperMm, 'code_page': codePage, 'drawer': drawer};

  factory PrinterConfig.fromJson(Map<String, dynamic>? j) => j == null
      ? PrinterConfig()
      : PrinterConfig(
          kind: j['kind'] as String? ?? 'none',
          name: j['name'] as String? ?? '',
          host: j['host'] as String? ?? '',
          port: (j['port'] as num?)?.toInt() ?? 9100,
          paperMm: (j['paper_mm'] as num?)?.toInt() ?? 80,
          codePage: (j['code_page'] as num?)?.toInt() ?? 17,
          drawer: j['drawer'] != false,
        );
}

class PrintError implements Exception {
  PrintError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Отправить готовые байты на принтер.
Future<void> sendToPrinter(PrinterConfig c, Uint8List data) async {
  switch (c.kind) {
    case 'network':
      await _sendTcp(c.host, c.port, data);
    case 'windows':
      if (!Platform.isWindows) throw PrintError(tr('Принтер Windows доступен только на Windows', 'Windows printeri faqat Windowsda ishlaydi'));
      _sendWindowsRaw(c.name, data);
    default:
      throw PrintError(tr('Принтер не выбран — откройте «Оборудование»', 'Printer tanlanmagan — «Uskunalar» boʻlimini oching'));
  }
}

Future<void> _sendTcp(String host, int port, Uint8List data) async {
  if (host.isEmpty) throw PrintError(tr('Укажите IP-адрес принтера', 'Printerning IP-manzilini kiriting'));
  Socket? s;
  try {
    s = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
    s.add(data);
    await s.flush();
  } on SocketException catch (e) {
    throw PrintError(tr('Принтер $host:$port не отвечает (${e.osError?.message ?? e.message})', 'Printer $host:$port javob bermayapti (${e.osError?.message ?? e.message})'));
  } finally {
    await s?.close();
  }
}

// ------------------------------------------------------------ Windows

final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

final class _PrinterInfo4 extends Struct {
  external Pointer<Utf16> pPrinterName;
  external Pointer<Utf16> pServerName;
  @Uint32()
  external int attributes;
}

typedef _OpenC = Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _OpenD = int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _StartDocC = Uint32 Function(IntPtr, Uint32, Pointer<_DocInfo1>);
typedef _StartDocD = int Function(int, int, Pointer<_DocInfo1>);
typedef _HC = Int32 Function(IntPtr);
typedef _HD = int Function(int);
typedef _WriteC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _WriteD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>);
typedef _EnumC = Int32 Function(Uint32, Pointer<Utf16>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint32>);
typedef _EnumD = int Function(int, Pointer<Utf16>, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>);

DynamicLibrary? _spool;
DynamicLibrary get _winspool => _spool ??= DynamicLibrary.open('winspool.drv');

void _sendWindowsRaw(String printer, Uint8List data) {
  if (printer.isEmpty) throw PrintError(tr('Выберите принтер Windows', 'Windows printerini tanlang'));
  final open = _winspool.lookupFunction<_OpenC, _OpenD>('OpenPrinterW');
  final startDoc = _winspool.lookupFunction<_StartDocC, _StartDocD>('StartDocPrinterW');
  final startPage = _winspool.lookupFunction<_HC, _HD>('StartPagePrinter');
  final write = _winspool.lookupFunction<_WriteC, _WriteD>('WritePrinter');
  final endPage = _winspool.lookupFunction<_HC, _HD>('EndPagePrinter');
  final endDoc = _winspool.lookupFunction<_HC, _HD>('EndDocPrinter');
  final close = _winspool.lookupFunction<_HC, _HD>('ClosePrinter');

  final name = printer.toNativeUtf16();
  final handle = calloc<IntPtr>();
  final doc = calloc<_DocInfo1>();
  final docName = 'Super Market POS'.toNativeUtf16();
  final rawType = 'RAW'.toNativeUtf16();
  final buf = calloc<Uint8>(data.length);
  final written = calloc<Uint32>();
  try {
    if (open(name, handle, nullptr) == 0) throw PrintError(tr('Принтер «$printer» не найден в Windows', '«$printer» printeri Windowsda topilmadi'));
    final h = handle.value;
    try {
      doc.ref
        ..pDocName = docName
        ..pOutputFile = nullptr
        ..pDatatype = rawType;
      if (startDoc(h, 1, doc) == 0) throw PrintError(tr('Windows не принял задание печати', 'Windows chop etish topshirigʻini qabul qilmadi'));
      startPage(h);
      buf.asTypedList(data.length).setAll(0, data);
      final ok = write(h, buf, data.length, written);
      endPage(h);
      endDoc(h);
      if (ok == 0 || written.value != data.length) throw PrintError(tr('Принтер «$printer» не принял данные', '«$printer» printeri maʼlumotlarni qabul qilmadi'));
    } finally {
      close(h);
    }
  } finally {
    calloc.free(name);
    calloc.free(handle);
    calloc.free(doc);
    calloc.free(docName);
    calloc.free(rawType);
    calloc.free(buf);
    calloc.free(written);
  }
}

/// Принтеры, установленные в Windows (локальные и сетевые подключения).
List<String> windowsPrinters() {
  if (!Platform.isWindows) return const [];
  final enumPrinters = _winspool.lookupFunction<_EnumC, _EnumD>('EnumPrintersW');
  const flags = 0x2 | 0x4; // PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS
  final needed = calloc<Uint32>();
  final count = calloc<Uint32>();
  try {
    enumPrinters(flags, nullptr, 4, nullptr, 0, needed, count);
    if (needed.value == 0) return const [];
    final buf = calloc<Uint8>(needed.value);
    try {
      if (enumPrinters(flags, nullptr, 4, buf, needed.value, needed, count) == 0) return const [];
      final infos = buf.cast<_PrinterInfo4>();
      return [for (var i = 0; i < count.value; i++) infos[i].pPrinterName.toDartString()];
    } finally {
      calloc.free(buf);
    }
  } finally {
    calloc.free(needed);
    calloc.free(count);
  }
}
