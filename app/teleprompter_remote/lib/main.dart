import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const TeleprompterRemoteApp());
}

class TeleprompterRemoteApp extends StatelessWidget {
  const TeleprompterRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Teleprompter Remote',
      theme: ThemeData.dark(useMaterial3: true),
      home: const RemoteScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  // UUID
  final Guid serviceUuid =
      Guid("12345678-1234-1234-1234-1234567890ab");
  final Guid charUuid =
      Guid("abcd1234-5678-90ab-cdef-1234567890ab");

  BluetoothDevice? device;
  BluetoothCharacteristic? cmdChar;

  bool scanning = false;
  bool connected = false;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  String status = "Disconnected";

  // ---- Text upload UI/state ----
  final TextEditingController textCtrl = TextEditingController();
  bool uploading = false;
  double uploadProgress = 0.0;

  // ---------------- Permissions ----------------
  Future<void> ensurePermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  // ---------------- Scan + Connect ----------------
  Future<void> startScan() async {
    if (scanning || uploading) return;

    await ensurePermissions();

    setState(() {
      scanning = true;
      status = "Scanning...";
    });

    await FlutterBluePlus.stopScan();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (final r in results) {
        final advName = r.advertisementData.advName;
        final devName = r.device.platformName;
        final name = advName.isNotEmpty ? advName : devName;

        if (name.toLowerCase().contains("teleprompter")) {
          await FlutterBluePlus.stopScan();
          await connectToDevice(r.device);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 8),
    );

    Future.delayed(const Duration(seconds: 8), () async {
      if (!connected) {
        await FlutterBluePlus.stopScan();
        if (mounted) {
          setState(() {
            scanning = false;
            status = "Not found. Tap Connect again.";
          });
        }
      }
    });
  }

  Future<void> connectToDevice(BluetoothDevice d) async {
    device = d;
    setState(() {
      status = "Connecting...";
    });

    try {
      await device!.connect(timeout: const Duration(seconds: 8));
    } catch (_) {
      // если уже подключено или был прошлый коннект
    }

    _connSub?.cancel();
    _connSub = device!.connectionState.listen((s) {
      final isConn = s == BluetoothConnectionState.connected;
      if (mounted) {
        setState(() {
          connected = isConn;
          scanning = false;
          status = isConn
              ? "Connected to ${device!.platformName}"
              : "Disconnected";
        });
      }

      if (!isConn) {
        cmdChar = null;
      }
    });

    await discoverCmdCharacteristic();
  }

  Future<void> discoverCmdCharacteristic() async {
    if (device == null) return;

    final services = await device!.discoverServices();
    for (final s in services) {
      if (s.uuid == serviceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == charUuid) {
            cmdChar = c;
            if (mounted) {
              setState(() {
                status = "Ready";
              });
            }
            return;
          }
        }
      }
    }
    if (mounted) {
      setState(() {
        status = "Characteristic not found";
      });
    }
  }

  // ---------------- Send single-char commands ----------------
  Future<void> sendCmd(String cmd) async {
    if (cmdChar == null || !connected || uploading) return;

    // команды можно слать без ответа
    await cmdChar!.write(
      utf8.encode(cmd),
      withoutResponse: true,
      timeout: 2,
    );
  }

  // ---------------- Upload full text ----------------
  Future<void> sendTextToEsp(String fullText) async {
    if (cmdChar == null || !connected || uploading) return;
    if (fullText.trim().isEmpty) {
      setState(() => status = "Text is empty");
      return;
    }

    setState(() {
      uploading = true;
      uploadProgress = 0.0;
      status = "Uploading text...";
    });

    try {
      int mtu = 23; // дефолт
      try {
        mtu = await device!.requestMtu(185); // фактическое MTU
      } catch (_) {}

      final data = utf8.encode(fullText);

      // payload = MTU - 3, и дополнительно режем до 180
      final int chunkSize = (mtu - 3).clamp(20, 180);

      // маркер старта — обязательно with response
      await cmdChar!.write(
        utf8.encode("TSTART\n"),
        withoutResponse: false,
        timeout: 2,
      );

      int sent = 0;

      for (int i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final chunk = data.sublist(i, end);

        // ВАЖНО: чанки шлём with response, чтобы BLE гарантировал доставку
        await cmdChar!.write(
          chunk,
          withoutResponse: false,
          timeout: 2,
        );

        sent += chunk.length;
        if (mounted) {
          setState(() => uploadProgress = sent / data.length);
        }
      }

      // маркер конца — with response
      await cmdChar!.write(
        utf8.encode("TEND\n"),
        withoutResponse: false,
        timeout: 2,
      );

      if (mounted) setState(() => status = "Text uploaded. Ready.");
    } catch (e) {
      if (mounted) setState(() => status = "Upload failed: $e");
    } finally {
      if (mounted) {
        setState(() {
          uploading = false;
          uploadProgress = 0.0;
        });
      }
    }
  }

  Future<void> disconnect() async {
    if (device == null) return;
    await FlutterBluePlus.stopScan();
    try {
      await device!.disconnect();
    } catch (_) {}
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    textCtrl.dispose();
    super.dispose();
  }

  // ---------------- UI helpers ----------------
  Widget bigButton(String text, VoidCallback onTap, {double size = 86}) {
    return SizedBox(
      width: size,
      height: size,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          padding: const EdgeInsets.all(8),
        ),
        onPressed: (connected && !uploading) ? onTap : null,
        child: Text(
          text,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSendText = connected && !uploading;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Teleprompter Remote"),
        actions: [
          if (connected)
            TextButton(
              onPressed: uploading ? null : disconnect,
              child: const Text("DISCONNECT"),
            )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // статус + connect
            Row(
              children: [
                Expanded(
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 16,
                      color: connected
                          ? Colors.greenAccent
                          : Colors.orangeAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: (scanning || uploading) ? null : startScan,
                  child: Text(scanning ? "SCANNING..." : "CONNECT"),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // поле текста
            TextField(
              controller: textCtrl,
              maxLines: 5,
              enabled: !uploading,
              decoration: const InputDecoration(
                labelText: "Paste teleprompter text here",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),

            // upload button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canSendText
                    ? () => sendTextToEsp(textCtrl.text)
                    : null,
                child: Text(uploading ? "UPLOADING..." : "UPLOAD TEXT"),
              ),
            ),

            if (uploading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: uploadProgress),
            ],

            const SizedBox(height: 20),

            // кнопки управления
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    bigButton("UP", () => sendCmd("u")),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        bigButton("-", () => sendCmd("-")),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 160,
                          height: 86,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                            onPressed: (connected && !uploading)
                                ? () => sendCmd("p")
                                : null,
                            child: const Text(
                              "PLAY\nPAUSE",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        bigButton("+", () => sendCmd("+")),
                      ],
                    ),
                    const SizedBox(height: 12),
                    bigButton("DOWN", () => sendCmd("d"), size: 120),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
