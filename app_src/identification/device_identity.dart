import 'dart:convert';

import 'company_ids.dart';

// ---------- Enums ----------

enum DeviceCategory {
  smartphone,
  smartwatch,
  headphones,
  speaker,
  fitnessTracker,
  smartHome,
  beacon,
  other,
  unknown,
}

extension DeviceCategoryLabel on DeviceCategory {
  String get label => switch (this) {
        DeviceCategory.smartphone => 'Smartphone',
        DeviceCategory.smartwatch => 'Smartwatch',
        DeviceCategory.headphones => 'Headphones / earbuds',
        DeviceCategory.speaker => 'Speaker',
        DeviceCategory.fitnessTracker => 'Fitness tracker',
        DeviceCategory.smartHome => 'Smart home device',
        DeviceCategory.beacon => 'BLE beacon',
        DeviceCategory.other => 'Other',
        DeviceCategory.unknown => 'Unknown',
      };
}

enum IdentificationStatus { identified, manufacturerKnown, nameUnavailable, unknown }

extension IdentificationStatusLabel on IdentificationStatus {
  String get label => switch (this) {
        IdentificationStatus.identified => 'Identified',
        IdentificationStatus.manufacturerKnown => 'Manufacturer known',
        IdentificationStatus.nameUnavailable => 'Name unavailable',
        IdentificationStatus.unknown => 'Unknown device',
      };
}

enum NameSource { advertised, androidCache, readFromDevice, earlierSighting, userNote }

extension NameSourceLabel on NameSource {
  String get label => switch (this) {
        NameSource.advertised => 'device advertisement',
        NameSource.androidCache => 'Android (paired or cached name)',
        NameSource.readFromDevice => 'read from the device on request',
        NameSource.earlierSighting => 'seen earlier in this session',
        NameSource.userNote => 'your own note',
      };
}

class CategoryGuess {
  final DeviceCategory category;
  final String reason; // shown to the user so the guess is transparent
  const CategoryGuess(this.category, this.reason);
}

// ---------- Identification logic ----------

class BleIdentity {
  static final _macLike =
      RegExp(r'^([0-9a-f]{2}[:\-]){5}[0-9a-f]{2}$', caseSensitive: false);

  /// Returns a usable device name, or null. Rejects empty text, control
  /// characters, MAC-address-looking text and the remote identifier itself.
  static String? cleanName(String? raw, {String? remoteId}) {
    if (raw == null) return null;
    final s = raw.replaceAll(RegExp(r'[\u0000-\u001F]'), '').trim();
    if (s.isEmpty) return null;
    if (_macLike.hasMatch(s)) return null;
    if (remoteId != null && s.toLowerCase() == remoteId.toLowerCase()) return null;
    return s;
  }

  static String? decodeName(List<int> bytes) =>
      cleanName(utf8.decode(bytes, allowMalformed: true));

  /// Company that registered the ID. Null when unlisted.
  static String? manufacturer(int? companyId) =>
      companyId == null ? null : kCompanyIds[companyId];

  // Brand words found inside an advertised name. This comes from the NAME, not
  // from the hardware, so the UI labels it as unverified.
  static const _brandWords = [
    ['jbl', 'JBL'],
    ['boat', 'boAt'],
    ['oneplus', 'OnePlus'],
    ['sony', 'Sony'],
    ['galaxy', 'Samsung'],
    ['samsung', 'Samsung'],
    ['airpods', 'Apple'],
    ['beats', 'Beats'],
    ['bose', 'Bose'],
    ['jabra', 'Jabra'],
    ['realme', 'realme'],
    ['redmi', 'Xiaomi'],
    ['mi band', 'Xiaomi'],
    ['amazfit', 'Amazfit'],
    ['garmin', 'Garmin'],
    ['fitbit', 'Fitbit'],
    ['fire-boltt', 'Fire-Boltt'],
  ];

  static String? brandFromName(String name) {
    final n = name.toLowerCase();
    for (final b in _brandWords) {
      if (n.contains(b[0])) return b[1];
    }
    return null;
  }

  static const _serviceHints = {
    '180d': 'Heart-rate service',
    '1812': 'Keyboard / mouse (HID) service',
    '1802': 'Immediate Alert service (used by tags and finders)',
    '181a': 'Environmental sensing service',
    '1826': 'Fitness machine service',
    'fe2c': 'Google Fast Pair accessory',
    'feaa': 'Eddystone beacon',
    'fd6f': 'Exposure Notification service',
  };

  static String? serviceHint(Set<String> services) {
    for (final s in services) {
      final h = _serviceHints[s];
      if (h != null) return h;
    }
    return null;
  }

  /// Category only when there is supporting evidence. Strongest first:
  /// advertised appearance, protocol-specific payloads, services, then name.
  static CategoryGuess? classify({
    int? appearance,
    int? companyId,
    List<int> payload = const [],
    Set<String> services = const {},
    String name = '',
  }) {
    // 1. GAP appearance (device states what it is).
    if (appearance != null && appearance > 0) {
      switch (appearance >> 6) {
        case 1:
          return const CategoryGuess(DeviceCategory.smartphone, 'device says it is a phone');
        case 3:
          return const CategoryGuess(DeviceCategory.smartwatch, 'device says it is a watch');
        case 37:
          return const CategoryGuess(
              DeviceCategory.headphones, 'device says it is wearable audio');
        case 13:
        case 17:
        case 18:
          return const CategoryGuess(DeviceCategory.fitnessTracker,
              'device says it is a heart-rate, running or cycling sensor');
        case 36:
          return const CategoryGuess(
              DeviceCategory.smartHome, 'device says it is a domestic appliance');
        case 8:
        case 9:
          return const CategoryGuess(DeviceCategory.other, 'device says it is a tag or keyring');
      }
    }

    // 2. Apple's advertisement type byte.
    if (companyId == 0x004C && payload.isNotEmpty) {
      if (payload[0] == 0x02 && payload.length >= 2 && payload[1] == 0x15) {
        return const CategoryGuess(DeviceCategory.beacon, 'iBeacon advertisement format');
      }
      if (payload[0] == 0x07) {
        return const CategoryGuess(DeviceCategory.headphones,
            'Apple pairing advertisement (AirPods/Beats-type accessory)');
      }
      if (payload[0] == 0x12) {
        return const CategoryGuess(
            DeviceCategory.other, 'Find My network advertisement (tracker or accessory)');
      }
    }

    // 3. Advertised services.
    if (services.contains('feaa')) {
      return const CategoryGuess(DeviceCategory.beacon, 'Eddystone beacon service');
    }
    if (services.contains('fd6f')) {
      return const CategoryGuess(DeviceCategory.smartphone, 'Exposure Notification service');
    }
    if (services.contains('180d') || services.contains('1826')) {
      return const CategoryGuess(DeviceCategory.fitnessTracker, 'heart-rate or fitness service');
    }
    if (services.contains('181a')) {
      return const CategoryGuess(DeviceCategory.smartHome, 'environmental sensing service');
    }

    // 4. Words in the name (weakest evidence).
    final n = name.toLowerCase();
    bool has(List<String> words) => words.any(n.contains);
    const why = 'words in the advertised name (weak evidence)';
    if (has(['airpods', 'earbud', 'earphone', 'headphone', 'headset', 'buds', 'neckband'])) {
      return const CategoryGuess(DeviceCategory.headphones, why);
    }
    if (has(['speaker', 'soundbar', 'boombox'])) {
      return const CategoryGuess(DeviceCategory.speaker, why);
    }
    if (has(['watch'])) return const CategoryGuess(DeviceCategory.smartwatch, why);
    if (has(['band', 'fitbit'])) {
      return const CategoryGuess(DeviceCategory.fitnessTracker, why);
    }
    if (has(['bulb', 'plug', 'lamp'])) return const CategoryGuess(DeviceCategory.smartHome, why);
    if (has(['beacon'])) return const CategoryGuess(DeviceCategory.beacon, why);

    return null;
  }

  static IdentificationStatus status({
    required bool hasName,
    required bool hasManufacturer,
    required bool hasOtherEvidence,
    bool nameReadFailed = false,
  }) {
    if (hasName) return IdentificationStatus.identified;
    if (hasManufacturer) return IdentificationStatus.manufacturerKnown;
    if (hasOtherEvidence || nameReadFailed) return IdentificationStatus.nameUnavailable;
    return IdentificationStatus.unknown;
  }
}
