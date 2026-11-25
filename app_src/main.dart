import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'identification/device_identity.dart';

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

const _suspectWords = ['cam', 'ipc', 'spy', 'hidden', 'ipcam', 'wifi', 'mini'];

class Tracked {
  final String id;

  // Names are kept separately so a valid name is never overwritten by an
  // empty one. Android merges advertisement + scan-response data, so
  // advName already includes a name sent in the scan response.
  String? advName;
  String? platformName; // Android's paired / cached name
  String? gattName; // read only when the user taps "Read name"
  String? observedName; // seen earlier in this session
  String? userNote;
  bool nameReadFailed = false;

  bool paired = false;
  bool? connectable;
  int? companyId;
  List<int> payload = const [];
  int? appearance;
  Set<String> services = {};

  double? ema; // smoothed RSSI
  int peak = -127;
  int txPower = -59; // assumed RSSI at 1 m
  DateTime lastSeen = DateTime.now();
  bool identifying = false;

  Tracked(this.id);

  // ----- identification -----

  String? get deviceName => advName ?? platformName ?? gattName ?? observedName;

  NameSource? get nameSource {
    if (advName != null) return NameSource.advertised;
    if (platformName != null) return NameSource.androidCache;
    if (gattName != null) return NameSource.readFromDevice;
    if (observedName != null) return NameSource.earlierSighting;
    if (userNote != null) return NameSource.userNote;
    return null;
  }

  String get displayName => deviceName ?? userNote ?? '';

  String? get manufacturer => DeviceIdentifier.manufacturer(companyId);

  CategoryGuess? get category => DeviceIdentifier.classify(
        appearance: appearance,
        companyId: companyId,
        payload: payload,
        services: services,
        name: deviceName ?? '',
      );

  String? get brandHint =>
      deviceName == null ? null : DeviceIdentifier.brandFromName(deviceName!);

  IdentificationStatus get status => DeviceIdentifier.status(
        hasName: deviceName != null,
        hasManufacturer: manufacturer != null,
        hasOtherEvidence:
            category != null || services.isNotEmpty || appearance != null,
        nameReadFailed: nameReadFailed,
      );

  // ----- signal tracking (unchanged) -----

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

  // Only a camera-like WORD in the name is noted. Unknown names or unknown
  // manufacturers are never treated as suspicious.
  bool get suspectName {
    final n = displayName.toLowerCase();
    return _suspectWords.any(n.contains);
  }

  bool get flagged => suspectName;
}

IconData _iconFor(DeviceCategory? c) => switch (c) {
      DeviceCategory.smartphone => Icons.smartphone,
      DeviceCategory.smartwatch => Icons.watch,
      DeviceCategory.headphones => Icons.headphones,
      DeviceCategory.speaker => Icons.speaker,
      DeviceCategory.fitnessTracker => Icons.fitness_center,
      DeviceCategory.smartHome => Icons.home,
      DeviceCategory.beacon => Icons.sensors,
      DeviceCategory.other => Icons.devices_other,
      _ => Icons.bluetooth,
    };

String _ago(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 2) return 'just now';
  if (s < 60) return '${s}s ago';
  return '${s ~/ 60}m ago';
}

// ---------- Screen ----------

class BleScreen extends StatefulWidget {
  const BleScreen({super.key});
  @override
  State<BleScreen> createState() => _BleScreenState();
}

class _BleScreenState extends State<BleScreen> {
  final Map<String, Tracked> _devices = {};
  final Map<String, String> _nameCache = {}; // id -> last valid name
  final Map<String, String> _userNotes = {}; // id -> user's own note (memory only)
  final Map<String, String?> _bonded = {}; // paired devices (Android)
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

    // Devices already paired with this phone: Android knows their names.
    try {
      _bonded.clear();
      for (final d in await FlutterBluePlus.bondedDevices) {
        _bonded[d.remoteId.str] =
            DeviceIdentifier.cleanName(d.platformName, remoteId: d.remoteId.str);
      }
    } catch (_) {
      // Not available on this platform; scanning still works.
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

  Future<void> _confirmAndIdentify(Tracked t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Connect briefly?'),
        content: const Text(
            'Sweep will connect to this device for a few seconds, only to ask '
            'for its name, then disconnect. It does not pair or change anything. '
            'If the device asks to pair, decline.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Connect')),
        ],
      ),
    );
    if (ok == true) await _identify(t);
  }

  // Read the standard Device Name (0x2A00). Only runs after the user confirms.
  Future<void> _identify(Tracked t) async {
    setState(() {
      t.identifying = true;
      t.nameReadFailed = false;
    });
    final dev = BluetoothDevice.fromId(t.id);
    String? name;
    try {
      await dev.connect(timeout: const Duration(seconds: 8));
      final services = await dev.discoverServices();
      for (final s in services) {
        if (s.uuid.str.toLowerCase() != '1800') continue;
        for (final c in s.characteristics) {
          if (c.uuid.str.toLowerCase() == '2a00') {
            name = DeviceIdentifier.decodeName(await c.read());
          }
        }
      }
    } catch (_) {
      name = null;
    } finally {
      try {
        await dev.disconnect();
      } catch (_) {}
    }
    if (name != null) {
      t.gattName = name;
      _nameCache[t.id] = name;
    } else {
      t.nameReadFailed = true; // never overwrites an existing name
    }
    if (mounted) setState(() => t.identifying = false);
  }

  Future<void> _editNote(Tracked t) async {
    final ctl = TextEditingController(text: t.userNote ?? '');
    final res = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Your note for this device'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'e.g. my watch, bedside speaker'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (res == null) return;
    final v = res.trim();
    setState(() {
      if (v.isEmpty) {
        t.userNote = null;
        _userNotes.remove(t.id);
      } else {
        t.userNote = v;
        _userNotes[t.id] = v;
      }
    });
  }

  void _onResults(List<ScanResult> results) {
    for (final r in results) {
      final id = r.device.remoteId.str;
      final ad = r.advertisementData;

      final t = _devices.putIfAbsent(id, () {
        final n = Tracked(id);
        n.observedName = _nameCache[id];
        n.userNote = _userNotes[id];
        n.paired = _bonded.containsKey(id);
        return n;
      });

      // Names: only ever replace with a valid, non-empty value.
      final adName = DeviceIdentifier.cleanName(ad.advName, remoteId: id);
      final platName = DeviceIdentifier.cleanName(r.device.platformName, remoteId: id) ??
          _bonded[id];
      if (adName != null) t.advName = adName;
      if (platName != null) t.platformName = platName;
      final seen = adName ?? platName;
      if (seen != null) _nameCache[id] = seen;

      if (ad.manufacturerData.isNotEmpty) {
        final e = ad.manufacturerData.entries.first;
        t.companyId = e.key;
        t.payload = e.value;
      }
      for (final g in ad.serviceUuids) {
        t.services.add(g.str.toLowerCase());
      }
      if (ad.appearance != null) t.appearance = ad.appearance;
      t.connectable = ad.connectable;

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
          if (sel != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: SingleChildScrollView(
                child: _MeterCard(
                  device: sel,
                  onClose: () => setState(() => _selected = null),
                  onIdentify: () => _confirmAndIdentify(sel),
                  onNote: () => _editNote(sel),
                ),
              ),
            ),
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
                final cat = d.category;
                final line1 = [
                  d.manufacturer ?? 'Unknown manufacturer',
                  if (cat != null) cat.category.label,
                ].join(' · ');
                return ListTile(
                  isThreeLine: true,
                  leading: Icon(
                    d.flagged ? Icons.warning_amber_rounded : _iconFor(cat?.category),
                    color: d.flagged ? Colors.orange : null,
                  ),
                  title: Text(d.displayName.isEmpty ? 'Unnamed device' : d.displayName),
                  subtitle: Text(
                      '$line1\n~${d.meters.toStringAsFixed(1)} m · ${_ago(d.lastSeen)}'),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${d.ema?.round() ?? "-"} dBm'),
                      Text(d.status.label, style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
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

// ---------- Hot / cold meter + identification details ----------

class _MeterCard extends StatelessWidget {
  final Tracked device;
  final VoidCallback onClose;
  final VoidCallback onIdentify;
  final VoidCallback onNote;
  const _MeterCard({
    required this.device,
    required this.onClose,
    required this.onIdentify,
    required this.onNote,
  });

  String get _label {
    final h = device.heat;
    if (h > 0.85) return 'Very close';
    if (h > 0.65) return 'Hot';
    if (h > 0.4) return 'Warm';
    return 'Cold';
  }

  List<String> get _details {
    final d = device;
    final cat = d.category;
    final hint = DeviceIdentifier.serviceHint(d.services);
    final cid = d.companyId == null
        ? ''
        : ' (company ID 0x${d.companyId!.toRadixString(16).padLeft(4, '0')})';
    return [
      'Status: ${d.status.label}',
      if (d.nameSource != null) 'Name from: ${d.nameSource!.label}',
      'Manufacturer: ${d.manufacturer ?? 'Unknown'}$cid',
      if (d.brandHint != null)
        'Brand in name: ${d.brandHint} (taken from the name, not verified)',
      if (cat != null) 'Category: ${cat.category.label}, based on ${cat.reason}',
      if (hint != null) 'Advertised service: $hint',
      'Connectable: ${d.connectable == null ? 'unknown' : (d.connectable! ? 'yes' : 'no')}',
      if (d.paired) 'Paired with this phone',
      if (d.userNote != null && d.deviceName != null) 'Your note: ${d.userNote}',
      if (d.nameReadFailed && d.deviceName == null)
        'Name could not be read (the device may not share one)',
    ];
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
                  device.displayName.isEmpty ? 'Unnamed device' : device.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            ]),
            Text(_label,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: color)),
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
            if (device.suspectName)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('The name contains a camera-like word. Worth a closer look.',
                    style: TextStyle(color: Colors.orange)),
              ),
            const Divider(height: 24),
            for (final line in _details)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(line, style: Theme.of(context).textTheme.bodySmall),
              ),
            if (device.manufacturer != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'The company ID shows who registered it, often the chip or '
                  'firmware maker, not always the product brand.',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              if (device.connectable != false)
                OutlinedButton.icon(
                  onPressed: device.identifying ? null : onIdentify,
                  icon: device.identifying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.badge_outlined),
                  label: Text(device.identifying ? 'Connecting...' : 'Read name'),
                ),
              OutlinedButton.icon(
                onPressed: onNote,
                icon: const Icon(Icons.edit_note),
                label: Text(device.userNote == null ? 'Add note' : 'Edit note'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
