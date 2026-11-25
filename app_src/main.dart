import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'identification/device_identity.dart';
import 'tracking/detector_view.dart';
import 'tracking/pulse_engine.dart';
import 'tracking/signal_tracker.dart';

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

  final SignalTracker signal = SignalTracker();
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

  String? get manufacturer => BleIdentity.manufacturer(companyId);

  CategoryGuess? get category => BleIdentity.classify(
        appearance: appearance,
        companyId: companyId,
        payload: payload,
        services: services,
        name: deviceName ?? '',
      );

  String? get brandHint =>
      deviceName == null ? null : BleIdentity.brandFromName(deviceName!);

  IdentificationStatus get status => BleIdentity.status(
        hasName: deviceName != null,
        hasManufacturer: manufacturer != null,
        hasOtherEvidence:
            category != null || services.isNotEmpty || appearance != null,
        nameReadFailed: nameReadFailed,
      );

  // ----- signal tracking (see tracking/signal_tracker.dart) -----

  double? get ema => signal.ema;
  int get peak => signal.peak;
  DateTime get lastSeen => signal.lastSeen;
  bool get isFresh => signal.isFresh();
  double get meters => signal.meters;
  String get distanceText => signal.distanceText;
  double get heat => signal.heat;
  Trend get trend => signal.trend;
  void update(int rssi, DateTime stamp) => signal.update(rssi, stamp);

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

String _trendGlyph(Trend t) => switch (t) {
      Trend.warmer => '▲ ',
      Trend.colder => '▼ ',
      _ => '',
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

  // Beep / vibrate / ripple timing for the tracked device.
  late final PulseEngine _engine = PulseEngine(heat: () {
    final d = _selected == null ? null : _devices[_selected];
    if (d == null || !d.isFresh) return null;
    return d.heat;
  });

  @override
  void dispose() {
    _stop();
    _engine.dispose();
    super.dispose();
  }

  void _syncEngine() {
    if (_scanning && _selected != null) {
      _engine.start();
    } else {
      _engine.stop();
    }
  }

  void _select(String? id) {
    setState(() => _selected = id);
    _syncEngine();
  }

  void _cycleOutput() {
    setState(() {
      _engine.output = switch (_engine.output) {
        PulseOutput.sound => PulseOutput.vibrate,
        PulseOutput.vibrate => PulseOutput.off,
        PulseOutput.off => PulseOutput.sound,
      };
    });
  }

  Future<void> _start() async {
    setState(() => _error = null);

    try {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      if (!mounted) return;

      // Android 12+ needs "Nearby devices"; Android 11 and older need Location.
      // permission_handler can report the Android 12 permissions oddly on older
      // phones, so scanning is blocked only when neither one is granted.
      final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final locOk = statuses[Permission.locationWhenInUse]?.isGranted ?? false;
      if (!scanOk && !locOk) {
        final blocked = statuses.values.any((s) => s.isPermanentlyDenied);
        setState(() => _error = blocked
            ? 'Bluetooth permission is blocked. Enable it in Settings.'
            : 'Bluetooth and location permission are required to scan nearby devices.');
        return;
      }

      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        if (mounted) setState(() => _error = 'Please turn Bluetooth on.');
        return;
      }

      // Devices already paired with this phone: Android knows their names.
      try {
        _bonded.clear();
        for (final d in await FlutterBluePlus.bondedDevices) {
          _bonded[d.remoteId.str] =
              BleIdentity.cleanName(d.platformName, remoteId: d.remoteId.str);
        }
      } catch (_) {
        // Not available on this platform; BLE scanning still works.
      }

      await _sub?.cancel();
      _sub = FlutterBluePlus.scanResults.listen(
        _onResults,
        onError: (Object error) {
          if (mounted) {
            setState(() => _error = 'Bluetooth scanning error: $error');
          }
        },
      );
      await FlutterBluePlus.startScan(
        continuousUpdates: true, // keep RSSI updating while walking
        androidScanMode: AndroidScanMode.lowLatency,
      );

      // Refresh the UI four times a second and drop stale devices.
      _ui?.cancel();
      _ui = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final cutoff = DateTime.now().subtract(const Duration(seconds: 15));
        _devices.removeWhere((k, v) => v.lastSeen.isBefore(cutoff) && k != _selected);
        if (mounted) setState(() {});
      });
      if (mounted) setState(() => _scanning = true);
      _syncEngine();
    } catch (error) {
      _engine.stop();
      _ui?.cancel();
      await _sub?.cancel();
      _sub = null;
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _scanning = false;
          _error = 'Unable to start Bluetooth scanning: $error';
        });
      }
    }
  }

  Future<void> _stop() async {
    _engine.stop();
    _ui?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
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
    if (t.identifying) return;
    setState(() {
      t.identifying = true;
      t.nameReadFailed = false;
    });
    final dev = BluetoothDevice.fromId(t.id);
    String? name;
    try {
      await dev.connect(license: License.nonprofit, timeout: const Duration(seconds: 8));
      final services = await dev.discoverServices();
      for (final s in services) {
        if (s.uuid.str.toLowerCase() != '1800') continue;
        for (final c in s.characteristics) {
          if (c.uuid.str.toLowerCase() == '2a00') {
            name = BleIdentity.decodeName(await c.read());
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
      t.gattName = BleIdentity.preferName(
        t.gattName,
        name,
        remoteId: t.id,
      );
      _nameCache[t.id] = BleIdentity.preferName(
        _nameCache[t.id],
        name,
        remoteId: t.id,
      )!;
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
      // The plugin re-sends old results; ignore devices not heard recently.
      if (DateTime.now().difference(r.timeStamp).inSeconds > 10) continue;

      final id = r.device.remoteId.str;
      final ad = r.advertisementData;

      final t = _devices.putIfAbsent(id, () {
        final n = Tracked(id);
        n.observedName = _nameCache[id];
        n.userNote = _userNotes[id];
        n.paired = _bonded.containsKey(id);
        return n;
      });

      // flutter_blue_plus exposes the Android advertisement and scan-response
      // local name together as advName. Keep valid values from each source
      // separately so the hierarchy remains explicit and stable.
      t.advName = BleIdentity.preferName(
        t.advName,
        ad.advName,
        remoteId: id,
      );
      t.platformName = BleIdentity.preferName(
        t.platformName,
        r.device.platformName,
        remoteId: id,
      );
      t.platformName = BleIdentity.preferName(
        t.platformName,
        _bonded[id],
        remoteId: id,
      );
      final seen = t.advName ?? t.platformName;
      if (seen != null) {
        _nameCache[id] = BleIdentity.preferName(
          _nameCache[id],
          seen,
          remoteId: id,
        )!;
      }

      if (ad.manufacturerData.isNotEmpty) {
        var selectedId = ad.manufacturerData.keys.first;
        for (final companyId in ad.manufacturerData.keys) {
          if (BleIdentity.manufacturer(companyId) != null) {
            selectedId = companyId;
            break;
          }
        }
        t.companyId = selectedId;
        t.payload = ad.manufacturerData[selectedId] ?? const [];
      }
      for (final g in ad.serviceUuids) {
        t.services.add(g.str.toLowerCase());
      }
      if (ad.appearance != null) t.appearance = ad.appearance;
      t.connectable = ad.connectable;

      t.update(r.rssi, r.timeStamp);
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
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.68),
              child: SingleChildScrollView(
                child: _MeterCard(
                  device: sel,
                  pulses: _engine.pulses,
                  output: _engine.output,
                  onOutput: _cycleOutput,
                  onClose: () => _select(null),
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
                  d.manufacturer ??
                      (d.brandHint != null
                          ? 'Brand in name: ${d.brandHint}'
                          : 'Unknown manufacturer'),
                  if (cat != null) cat.category.label,
                ].join(' · ');
                return ListTile(
                  isThreeLine: true,
                  leading: Icon(
                    d.flagged ? Icons.warning_amber_rounded : _iconFor(cat?.category),
                    color: d.flagged ? Colors.orange : null,
                  ),
                  title: Text(d.displayName.isEmpty ? 'Unnamed device' : d.displayName),
                  subtitle: Text('$line1\n${d.distanceText} · ${_ago(d.lastSeen)}'),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${_trendGlyph(d.trend)}${d.ema?.round() ?? "-"} dBm'),
                      Text(d.status.label, style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                  selected: d.id == _selected,
                  onTap: () => _select(d.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Detector card ----------

class _MeterCard extends StatelessWidget {
  final Tracked device;
  final ValueListenable<int> pulses;
  final PulseOutput output;
  final VoidCallback onOutput;
  final VoidCallback onClose;
  final VoidCallback onIdentify;
  final VoidCallback onNote;
  const _MeterCard({
    required this.device,
    required this.pulses,
    required this.output,
    required this.onOutput,
    required this.onClose,
    required this.onIdentify,
    required this.onNote,
  });

  String get _label {
    if (!device.isFresh) return 'No signal';
    final h = device.heat;
    if (h > 0.85) return 'Very close';
    if (h > 0.65) return 'Hot';
    if (h > 0.4) return 'Warm';
    return 'Cold';
  }

  String get _trendText => switch (device.trend) {
        Trend.warmer => '▲ Getting warmer (closer)',
        Trend.colder => '▼ Getting colder (farther)',
        Trend.steady => '● Steady',
        Trend.unknown => 'Move around to see the trend',
      };

  Color get _trendColor => switch (device.trend) {
        Trend.warmer => Colors.red,
        Trend.colder => Colors.blue,
        _ => Colors.grey,
      };

  IconData get _outputIcon => switch (output) {
        PulseOutput.sound => Icons.volume_up,
        PulseOutput.vibrate => Icons.vibration,
        PulseOutput.off => Icons.volume_off,
      };

  String get _outputLabel => switch (output) {
        PulseOutput.sound => 'Sound',
        PulseOutput.vibrate => 'Vibrate',
        PulseOutput.off => 'Silent',
      };

  List<String> get _details {
    final d = device;
    final cat = d.category;
    final hint = BleIdentity.serviceHint(d.services);
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
    final theme = Theme.of(context);
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
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            ]),
            Center(
              child: SizedBox(
                width: 230,
                height: 230,
                child: DetectorView(
                  heat: device.heat,
                  color: color,
                  pulses: pulses,
                  title: _label,
                  subtitle: '${device.distanceText} · ${device.ema?.round()} dBm',
                ),
              ),
            ),
            Center(
              child: Text(_trendText,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: _trendColor, fontWeight: FontWeight.w600)),
            ),
            Center(
              child: Text('Peak ${device.peak} dBm', style: theme.textTheme.bodySmall),
            ),
            if (device.suspectName)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('The name contains a camera-like word. Worth a closer look.',
                    style: TextStyle(color: Colors.orange)),
              ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: onOutput,
                icon: Icon(_outputIcon),
                label: Text(_outputLabel),
              ),
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
            ExpansionTile(
              title: const Text('Details'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(line, style: theme.textTheme.bodySmall),
                  ),
                if (device.manufacturer != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'The company ID shows who registered it, often the chip or '
                      'firmware maker, not always the product brand.',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
