import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const SweepApp());

class SweepApp extends StatelessWidget {
  const SweepApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Sweep',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const BleScreen(),
      );
}

// ---------- Model ----------

const _companyIds = {
  0x004C: 'Apple',
  0x0006: 'Microsoft',
  0x0075: 'Samsung',
  0x00E0: 'Google',
  0x0059: 'Nordic Semi',
};

const _suspectWords = ['cam', 'ipc', 'spy', 'hidden', 'ipcam', 'wifi', 'mini'];

class Tracked {
  final String id;
  String name;
  String maker;
  double? ema; // smoothed RSSI
  int peak = -127;
  int txPower = -59; // assumed RSSI at 1 m
  DateTime lastSeen = DateTime.now();

  Tracked(this.id, this.name, this.maker);

  void update(int rssi, int? tx) {
    const alpha = 0.25;
    ema = ema == null ? rssi.toDouble() : alpha * rssi + (1 - alpha) * ema!;
    if (rssi > peak) peak = rssi;
    if (tx != null) txPower = tx;
    lastSeen = DateTime.now();
  }

  // Very rough. Treat as "about", never exact.
  double get meters {
    const n = 2.5;
    return pow(10, (txPower - (ema ?? -100)) / (10 * n)).toDouble();
  }

  // 0.0 (cold) .. 1.0 (hot)
  double get heat => (((ema ?? -100) + 100) / 60).clamp(0.0, 1.0);

  bool get unidentified => name.isEmpty && maker.startsWith('Unknown');

  bool get suspectName {
    final n = name.toLowerCase();
    return _suspectWords.any(n.contains);
  }

  bool get flagged => unidentified || suspectName;
}

// ---------- Screen ----------

class BleScreen extends StatefulWidget {
  const BleScreen({super.key});
  @override
  State<BleScreen> createState() => _BleScreenState();
}

class _BleScreenState extends State<BleScreen> {
  final Map<String, Tracked> _devices = {};
  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _ui;
  bool _scanning = false;
  String? _selected;
  String? _error;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final denied = statuses.values.any((s) => s.isPermanentlyDenied);
    if (denied) {
      setState(() => _error = 'Bluetooth permission is blocked. Enable it in Settings.');
      return;
    }

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      setState(() => _error = 'Please turn Bluetooth on.');
      return;
    }

    _sub = FlutterBluePlus.scanResults.listen(_onResults);
    await FlutterBluePlus.startScan(
      continuousUpdates: true, // keep RSSI updating while walking
      androidScanMode: AndroidScanMode.lowLatency,
    );

    // Refresh UI twice a second and drop stale devices.
    _ui = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final cutoff = DateTime.now().subtract(const Duration(seconds: 15));
      _devices.removeWhere((k, v) => v.lastSeen.isBefore(cutoff) && k != _selected);
      if (mounted) setState(() {});
    });
    setState(() => _scanning = true);
  }

  Future<void> _stop() async {
    _ui?.cancel();
    await _sub?.cancel();
    await FlutterBluePlus.stopScan();
    if (mounted) setState(() => _scanning = false);
  }

  void _onResults(List<ScanResult> results) {
    for (final r in results) {
      final id = r.device.remoteId.str;
      final ad = r.advertisementData;
      final name = ad.advName.isNotEmpty ? ad.advName : r.device.platformName;

      String maker = 'Unknown';
      if (ad.manufacturerData.isNotEmpty) {
        final cid = ad.manufacturerData.keys.first;
        maker = _companyIds[cid] ??
            'Unknown (0x${cid.toRadixString(16).padLeft(4, '0')})';
      }

      final t = _devices.putIfAbsent(id, () => Tracked(id, name, maker));
      if (name.isNotEmpty) t.name = name;
      t.update(r.rssi, ad.txPowerLevel);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _devices.values.toList()
      ..sort((a, b) => (b.ema ?? -127).compareTo(a.ema ?? -127));
    final sel = _selected == null ? null : _devices[_selected];

    return Scaffold(
      appBar: AppBar(title: const Text('Sweep · Bluetooth')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? _stop : _start,
        icon: Icon(_scanning ? Icons.stop : Icons.radar),
        label: Text(_scanning ? 'Stop' : 'Start sweep'),
      ),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('OK'))
              ],
            ),
          if (sel != null) _MeterCard(device: sel, onClose: () => setState(() => _selected = null)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _scanning
                  ? 'Walk slowly around the room. Tap a device to track it.'
                  : 'Tap Start sweep to scan.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 90),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final d = list[i];
                return ListTile(
                  leading: Icon(
                    d.flagged ? Icons.warning_amber_rounded : Icons.bluetooth,
                    color: d.flagged ? Colors.orange : null,
                  ),
                  title: Text(d.name.isEmpty ? 'Unnamed device' : d.name),
                  subtitle: Text('${d.maker} · ~${d.meters.toStringAsFixed(1)} m'),
                  trailing: Text('${d.ema?.round() ?? "-"} dBm'),
                  selected: d.id == _selected,
                  onTap: () => setState(() => _selected = d.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Hot / cold meter ----------

class _MeterCard extends StatelessWidget {
  final Tracked device;
  final VoidCallback onClose;
  const _MeterCard({required this.device, required this.onClose});

  String get _label {
    final h = device.heat;
    if (h > 0.85) return 'Very close';
    if (h > 0.65) return 'Hot';
    if (h > 0.4) return 'Warm';
    return 'Cold';
  }

  @override
  Widget build(BuildContext context) {
    final color = Color.lerp(Colors.blue, Colors.red, device.heat)!;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  device.name.isEmpty ? 'Unnamed device' : device.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            ]),
            Text(_label,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(color: color)),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: device.heat,
              minHeight: 14,
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 8),
            Text('Now ${device.ema?.round()} dBm · Peak ${device.peak} dBm · '
                'about ${device.meters.toStringAsFixed(1)} m'),
            if (device.flagged)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Unidentified or camera-like name. Worth checking.',
                    style: TextStyle(color: Colors.orange)),
              ),
            const SizedBox(height: 4),
            Text('Signal peaking as you move toward one spot means the source is near there.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
