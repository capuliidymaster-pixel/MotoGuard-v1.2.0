import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'map.dart';

// ================================================================
// FIREBASE CONFIGURATION
// ================================================================

const String motoDatabaseUrl =
    'https://seretei8-default-rtdb.asia-southeast1.firebasedatabase.app';

// ================================================================
// TIME CONFIGURATION (PHILIPPINES, UTC+8)
// ================================================================

const Duration phOffset = Duration(hours: 8);

/// Itakda sa `true` KUNG ang ESP32 mo ay nagpapadala ng epoch na may
/// idinagdag nang +8 oras (gmtOffset_sec = 28800 sa configTime).
const bool deviceSendsPhilippineLocalEpoch = false;

DateTime toPhilippineTime(DateTime t) => t.toUtc().add(phOffset);

String formatPhilippineTime(DateTime t) =>
    DateFormat('MMM d, yyyy • h:mm a').format(toPhilippineTime(t));

DateTime? parseTimestampOrNull(dynamic value, {bool deviceEpoch = false}) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;

  if (value is num) {
    final v = value.toDouble();
    int ms;

    if (v >= 1e14) {
      ms = (v / 1000).round(); // microseconds
    } else if (v >= 1e11) {
      ms = v.round(); // milliseconds
    } else if (v >= 1e9) {
      ms = (v * 1000).round(); // seconds
    } else {
      return null; // hindi epoch (hal. millis() uptime)
    }

    var dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    if (deviceEpoch && deviceSendsPhilippineLocalEpoch) {
      dt = dt.subtract(phOffset);
    }
    return dt;
  }

  if (value is String) {
    final s = value.trim();
    if (s.isEmpty) return null;

    final numeric = num.tryParse(s);
    if (numeric != null) {
      return parseTimestampOrNull(numeric, deviceEpoch: deviceEpoch);
    }

    final parsed = DateTime.tryParse(s);
    if (parsed == null) return null;

    final hasZone =
        RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(s);
    if (hasZone) return parsed;

    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
    ).subtract(phOffset);
  }

  return null;
}

/// Ang mga Firebase push key (hal. `-NxYz...`) ay may naka-encode na
/// oras ng pagkakagawa sa unang 8 character. Ginagamit natin ito para
/// magkaroon ng TAMANG oras ang bawat event kahit walang timestamp
/// field, imbes na pare-parehong "ngayon" ang lahat.
const String _pushChars =
    '-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz';

DateTime? _timeFromPushId(String id) {
  if (id.length != 20) return null;

  int ms = 0;
  for (var i = 0; i < 8; i++) {
    final idx = _pushChars.indexOf(id[i]);
    if (idx < 0) return null;
    ms = ms * 64 + idx;
  }

  // Sanity check: 2015 – 2100 lang ang tatanggapin.
  if (ms < 1420070400000 || ms > 4102444800000) return null;

  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

double? _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int _newestFirst(MotoNotification a, MotoNotification b) {
  final c = b.timestamp.compareTo(a.timestamp);
  if (c != 0) return c;
  return b.id.compareTo(a.id);
}

// ================================================================
// PHONE (SYSTEM) NOTIFICATIONS
// ================================================================

/// Nagpapakita ng notification sa status bar / notification tray ng phone.
class LocalAlertService {
  LocalAlertService._();
  static final LocalAlertService instance = LocalAlertService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // Dapat kapareho ng channel sa PushService / Cloud Function.
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'motoguard_alerts',
    'MotoGuard Alerts',
    description: 'Security and accident alerts from your MotoGuard device',
    importance: Importance.max,
  );

  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_channel);
    await android?.requestNotificationsPermission(); // Android 13+

    _ready = true;
  }

  Future<void> show({
    required String id,
    required String title,
    required String body,
  }) async {
    if (!_ready) await init();

    await _plugin.show(
      id: id.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          ticker: title,
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  /// Tinatanggal ang lahat ng naka-display na notification sa tray ng
  /// phone (ginagamit kapag "Mark all read").
  Future<void> clearAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }
}

// ================================================================
// DEVICE MODELS
// ================================================================

class OwnedDevice {
  final String id;
  final String name;

  const OwnedDevice({
    required this.id,
    required this.name,
  });
}

class DeviceStatus {
  final bool online;
  final DateTime? lastSeen;

  const DeviceStatus({
    required this.online,
    this.lastSeen,
  });
}

// ================================================================
// NOTIFICATION MODEL
// ================================================================

class MotoNotification {
  final String id;
  final String deviceId;
  final String title;
  final String message;
  final String type;
  final DateTime timestamp;
  final bool read;
  final double? latitude;
  final double? longitude;
  final bool fromSensorEvents;

  const MotoNotification({
    required this.id,
    required this.deviceId,
    required this.title,
    required this.message,
    required this.type,
    required this.timestamp,
    this.read = false,
    this.latitude,
    this.longitude,
    this.fromSensorEvents = false,
  });

  factory MotoNotification.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc, {
    DateTime? fallbackTime,
  }) {
    final data = doc.data() ?? {};

    final time = parseTimestampOrNull(data['timestamp']) ??
        parseTimestampOrNull(data['createdAt']) ??
        fallbackTime ??
        DateTime.now();

    return MotoNotification(
      id: doc.id,
      deviceId: (data['deviceId'] ?? '').toString(),
      title: (data['title'] ?? 'MotoGuard Notification').toString(),
      message: (data['message'] ?? 'New device event').toString(),
      type: (data['type'] ?? data['eventType'] ?? 'INFO')
          .toString()
          .toUpperCase(),
      timestamp: time,
      read: data['read'] == true,
      latitude: _toDouble(data['latitude'] ?? data['lat']),
      longitude: _toDouble(data['longitude'] ?? data['lng']),
      fromSensorEvents: false,
    );
  }

  MotoNotification copyWith({bool? read}) {
    return MotoNotification(
      id: id,
      deviceId: deviceId,
      title: title,
      message: message,
      type: type,
      timestamp: timestamp,
      read: read ?? this.read,
      latitude: latitude,
      longitude: longitude,
      fromSensorEvents: fromSensorEvents,
    );
  }
}

class _Seen {
  final String signature;
  final DateTime time;

  const _Seen(this.signature, this.time);
}

// ================================================================
// NOTIFICATION SERVICE
// ================================================================

class NotificationService extends ChangeNotifier {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  late final FirebaseDatabase _database = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: motoDatabaseUrl,
  );

  final ValueNotifier<List<OwnedDevice>> devices =
      ValueNotifier<List<OwnedDevice>>([]);

  final ValueNotifier<Map<String, DeviceStatus>> statuses =
      ValueNotifier<Map<String, DeviceStatus>>({});

  final ValueNotifier<List<MotoNotification>> all =
      ValueNotifier<List<MotoNotification>>([]);

  final ValueNotifier<bool> loaded = ValueNotifier<bool>(false);
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _deviceSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _notificationSub;

  final Map<String, StreamSubscription<DatabaseEvent>> _statusSubs = {};
  final Map<String, StreamSubscription<DatabaseEvent>> _eventSubs = {};

  final Map<String, MotoNotification> _sensorEvents = {};

  /// Mga sensor event na nabasa na (id -> signature ng event na nabasa).
  /// Kapag nagbago ang signature (bagong event sa parehong id), muling
  /// magiging "unread" at iilaw ito ulit.
  final Map<String, String> _readSensorSignatures = {};

  /// Mga Firestore notification na minarkahan nang nabasa (optimistic),
  /// para agad mawala ang ilaw kahit hindi pa bumabalik ang snapshot.
  final Set<String> _readFirestoreIds = {};

  final List<String> _registeredDeviceIds = [];

  final Map<String, _Seen> _seen = {};

  /// Mga event na na-notify na (id -> signature), para hindi mag-duplicate
  /// ang notification sa phone.
  final Map<String, String> _notified = {};

  /// Mga device na tapos na ang unang load. Ang unang snapshot ay
  /// "baseline" lang (lumang history), kaya hindi ito nagpapa-notify.
  final Set<String> _baselineDone = {};

  String? _currentUid;
  bool _started = false;

  Listenable get changes => Listenable.merge([
        devices,
        statuses,
        all,
        loaded,
        error,
        this,
      ]);

  DateTime _receivedTime(String key, String signature) {
    final prev = _seen[key];
    if (prev != null && prev.signature == signature) return prev.time;

    final now = DateTime.now();
    _seen[key] = _Seen(signature, now);
    return now;
  }

  /// Signature na tumutukoy kung "iisang event" pa rin ang notification.
  /// - Accident / Suspicious: nagbabago kapag nagbago ang oras nito, kaya
  ///   ang BAGONG event ay muling iilaw.
  /// - Ibang raw sensor data: id lang, para hindi muling umilaw sa bawat
  ///   pagbabago ng accelerometer reading.
  String _signatureFor(MotoNotification n) {
    final important = n.type == 'ACCIDENT' || n.type == 'SUSPICIOUS_MOVEMENT';
    if (!important) return n.id;
    return '${n.type}|${n.timestamp.millisecondsSinceEpoch}';
  }

  Future<void> start() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      error.value = 'Please sign in to view notifications.';
      loaded.value = true;
      return;
    }

    if (_started && _currentUid == user.uid) return;

    await _stopUserListeners();

    _started = true;
    _currentUid = user.uid;
    loaded.value = false;
    error.value = null;

    await LocalAlertService.instance.init();

    _listenForDevices(user.uid);
    _listenForFirestoreNotifications(user.uid);
  }

  void _listenForDevices(String uid) {
    _deviceSub = _firestore
        .collection('iotDevices')
        .where('connectedUserId', isEqualTo: uid)
        .snapshots()
        .listen(
      (snapshot) {
        final nextDevices = <OwnedDevice>[];
        final nextIds = <String>[];

        for (final doc in snapshot.docs) {
          final data = doc.data();

          final id = doc.id;
          final name = (data['deviceName'] ??
                  data['motorcycleName'] ??
                  data['name'] ??
                  id)
              .toString();

          nextDevices.add(OwnedDevice(id: id, name: name));
          nextIds.add(id);

          _listenSensorEvents(id);
          _listenDeviceStatus(id);
        }

        final removedIds =
            _registeredDeviceIds.where((id) => !nextIds.contains(id)).toList();

        for (final id in removedIds) {
          _eventSubs.remove(id)?.cancel();
          _statusSubs.remove(id)?.cancel();

          _sensorEvents.removeWhere((key, value) => value.deviceId == id);
          _readSensorSignatures
              .removeWhere((key, value) => key.startsWith('$id:'));
          _seen.removeWhere((key, value) => key.startsWith('rtdb:$id:'));
          _notified.removeWhere((key, value) => key.startsWith('$id:'));
          _baselineDone.remove(id);
        }

        _registeredDeviceIds
          ..clear()
          ..addAll(nextIds);

        devices.value = nextDevices;
        _refreshVisibleListeners();
        loaded.value = true;
        error.value = null;
      },
      onError: (e) {
        error.value = 'Unable to load registered devices: $e';
        loaded.value = true;
      },
    );
  }

  void _listenForFirestoreNotifications(String uid) {
    _notificationSub = _firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .snapshots()
        .listen(
      (snapshot) {
        final list = snapshot.docs.map((doc) {
          final n = MotoNotification.fromDoc(
            doc,
            fallbackTime: _receivedTime('fs:${doc.id}', ''),
          );

          // Panatilihing "read" kung minarkahan na natin ito locally.
          if (!n.read && _readFirestoreIds.contains(n.id)) {
            return n.copyWith(read: true);
          }
          return n;
        }).toList()
          ..sort(_newestFirst);

        all.value = list;
        notifyListeners();
      },
      onError: (e) {
        error.value = 'Unable to load notification history: $e';
      },
    );
  }

  // ==============================================================
  // READ DIRECTLY FROM sensorEvents/{deviceId}
  // ==============================================================

  void _listenSensorEvents(String deviceId) {
    if (_eventSubs.containsKey(deviceId)) return;

    final ref = _database.ref('sensorEvents/$deviceId');

    _eventSubs[deviceId] = ref.onValue.listen(
      (event) {
        final snapshot = event.snapshot;
        final parsed = <String, MotoNotification>{};

        if (!snapshot.exists || snapshot.value == null) {
          _sensorEvents.removeWhere((key, value) => value.deviceId == deviceId);
          _baselineDone.add(deviceId);
          _refreshVisibleListeners();
          return;
        }

        final value = snapshot.value;

        if (value is Map) {
          final map = Map<String, dynamic>.from(value);

          final hasDirectSensorFields = map.containsKey('accelX') ||
              map.containsKey('accelY') ||
              map.containsKey('accelZ') ||
              map.containsKey('eventType') ||
              map.containsKey('type') ||
              map.containsKey('message') ||
              map.containsKey('timestamp');

          if (hasDirectSensorFields) {
            final notification = _parseSensorRecord(
              deviceId: deviceId,
              eventId: 'current_sensor_data',
              data: map,
            );

            parsed[notification.id] = notification;
          } else {
            for (final entry in map.entries) {
              if (entry.value is! Map) continue;

              final record = Map<String, dynamic>.from(entry.value as Map);

              final notification = _parseSensorRecord(
                deviceId: deviceId,
                eventId: entry.key.toString(),
                data: record,
              );

              parsed[notification.id] = notification;
            }
          }
        }

        _sensorEvents.removeWhere((key, value) => value.deviceId == deviceId);
        _sensorEvents.addAll(parsed);

        // I-trigger ang phone notification para sa mga BAGONG event.
        _notifyNewEvents(deviceId, parsed.values);

        _refreshVisibleListeners();
      },
      onError: (e) {
        error.value = 'Unable to read sensorEvents/$deviceId: $e';
      },
    );
  }

  /// Nagpapakita ng phone notification para sa bagong Accident /
  /// Suspicious Movement. Ang unang load ng device ay baseline lang.
  void _notifyNewEvents(
    String deviceId,
    Iterable<MotoNotification> events,
  ) {
    final isBaseline = !_baselineDone.contains(deviceId);

    for (final n in events) {
      final signature =
          '${n.type}|${n.message}|${n.timestamp.millisecondsSinceEpoch}';

      final previous = _notified[n.id];
      _notified[n.id] = signature;

      if (isBaseline) continue; // lumang history, huwag i-notify
      if (previous == signature) continue; // na-notify na
      if (n.read) continue; // nabasa na, huwag nang i-notify

      final important = n.type == 'ACCIDENT' || n.type == 'SUSPICIOUS_MOVEMENT';
      if (!important) continue; // iwas spam sa raw sensor data

      LocalAlertService.instance.show(
        id: n.id,
        title: '${n.title} • ${deviceName(deviceId)}',
        body: n.message,
      );
    }

    _baselineDone.add(deviceId);
  }

  MotoNotification _parseSensorRecord({
    required String deviceId,
    required String eventId,
    required Map<String, dynamic> data,
  }) {
    final rawType = (data['eventType'] ??
            data['type'] ??
            data['event'] ??
            data['level'] ??
            '')
        .toString()
        .toUpperCase();

    final rawMessage =
        (data['message'] ?? data['description'] ?? data['alert'] ?? '')
            .toString()
            .trim();

    final normalizedType = rawType.replaceAll(RegExp(r'[^A-Z0-9]'), '');

    final isAccident = normalizedType.contains('ACCIDENT') ||
        normalizedType.contains('EMERGENCY') ||
        normalizedType == 'LEVEL2' ||
        normalizedType == '2';

    final isSuspicious = normalizedType.contains('SUSPICIOUS') ||
        normalizedType.contains('MOVEMENT') ||
        normalizedType == 'LEVEL1' ||
        normalizedType == '1';

    String title;
    String type;
    String defaultMessage;

    if (isAccident) {
      title = 'Possible Accident';
      type = 'ACCIDENT';
      defaultMessage = 'A possible accident event was detected.';
    } else if (isSuspicious) {
      title = 'Suspicious Movement';
      type = 'SUSPICIOUS_MOVEMENT';
      defaultMessage = 'Suspicious movement was detected.';
    } else {
      title = 'Sensor Event';
      type = rawType.isNotEmpty ? rawType : 'SENSOR_EVENT';
      defaultMessage = 'New sensor data was received from $deviceId.';
    }

    final hasAccelerometer = data.containsKey('accelX') ||
        data.containsKey('accelY') ||
        data.containsKey('accelZ');

    String message = rawMessage.isNotEmpty ? rawMessage : defaultMessage;

    if (rawType.isEmpty && hasAccelerometer) {
      final x = data['accelX'] ?? '--';
      final y = data['accelY'] ?? '--';
      final z = data['accelZ'] ?? '--';

      message = 'Accelerometer data: X=$x, Y=$y, Z=$z';
    }

    // ------------------------------------------------------------
    // TIMESTAMP: bawat event ay may sariling oras.
    //   1) timestamp field mula sa device
    //   2) oras na naka-encode sa Firebase push key
    //   3) huling fallback: oras ng pagtanggap (naka-cache kada event)
    // ------------------------------------------------------------
    final deviceTime = parseTimestampOrNull(
      data['timestamp'] ??
          data['createdAt'] ??
          data['time'] ??
          data['date'] ??
          data['ts'] ??
          data['epoch'] ??
          data['dateTime'],
      deviceEpoch: true,
    );

    final time = deviceTime ??
        _timeFromPushId(eventId) ??
        _receivedTime('rtdb:$deviceId:$eventId', data.toString());

    final base = MotoNotification(
      id: '$deviceId:$eventId',
      deviceId: deviceId,
      title: title,
      message: message,
      type: type,
      timestamp: time,
      read: false,
      latitude: _toDouble(
        data['latitude'] ?? data['lat'] ?? data['gpsLatitude'],
      ),
      longitude: _toDouble(
        data['longitude'] ?? data['lng'] ?? data['gpsLongitude'],
      ),
      fromSensorEvents: true,
    );

    final isRead = _readSensorSignatures[base.id] == _signatureFor(base);

    return isRead ? base.copyWith(read: true) : base;
  }

  // ==============================================================
  // DEVICE ONLINE/OFFLINE STATUS
  // ==============================================================

  void _listenDeviceStatus(String deviceId) {
    if (_statusSubs.containsKey(deviceId)) return;

    _statusSubs[deviceId] = _database.ref('gps/$deviceId').onValue.listen(
      (event) {
        final value = event.snapshot.value;
        bool online = false;
        DateTime? lastSeen;

        if (value is Map) {
          final data = Map<String, dynamic>.from(value);

          final status = (data['status'] ?? '').toString().toUpperCase();
          online = status == 'ONLINE' ||
              status == 'GPS_ONLINE' ||
              data['online'] == true;

          final rawTime =
              data['lastSeen'] ?? data['timestamp'] ?? data['updatedAt'];

          lastSeen = parseTimestampOrNull(rawTime, deviceEpoch: true);
        }

        final updated = Map<String, DeviceStatus>.from(statuses.value);
        updated[deviceId] = DeviceStatus(
          online: online,
          lastSeen: lastSeen,
        );

        statuses.value = updated;
        notifyListeners();
      },
      onError: (_) {},
    );
  }

  DeviceStatus statusOf(String deviceId) {
    return statuses.value[deviceId] ?? const DeviceStatus(online: false);
  }

  bool isOnline(String deviceId) => statusOf(deviceId).online;

  DateTime? lastSeen(String deviceId) => statusOf(deviceId).lastSeen;

  String deviceName(String deviceId) {
    for (final device in devices.value) {
      if (device.id == deviceId) return device.name;
    }
    return deviceId;
  }

  // ==============================================================
  // COMBINED HISTORY (NEWEST FIRST)
  // ==============================================================

  List<MotoNotification> get visible {
    final registered = _registeredDeviceIds.toSet();
    final combined = <String, MotoNotification>{};

    for (final notification in all.value) {
      if (registered.contains(notification.deviceId)) {
        combined[notification.id] =
            (!notification.read && _readFirestoreIds.contains(notification.id))
                ? notification.copyWith(read: true)
                : notification;
      }
    }

    for (final notification in _sensorEvents.values) {
      if (registered.contains(notification.deviceId)) {
        combined[notification.id] = notification;
      }
    }

    final result = combined.values.toList()..sort(_newestFirst);

    return result;
  }

  int get unreadCount => visible.where((n) => !n.read).length;

  void _refreshVisibleListeners() {
    all.value = List<MotoNotification>.from(all.value);
    notifyListeners();
  }

  // ==============================================================
  // MARK AS READ
  // ==============================================================

  Future<void> markRead(String notificationId) async {
    final sensorNotification = _sensorEvents[notificationId];

    if (sensorNotification != null) {
      if (sensorNotification.read) return;

      _readSensorSignatures[notificationId] = _signatureFor(sensorNotification);
      _sensorEvents[notificationId] = sensorNotification.copyWith(read: true);
      _refreshVisibleListeners();
      return;
    }

    final firestoreNotification = all.value.where(
      (n) => n.id == notificationId && !n.fromSensorEvents,
    );

    if (firestoreNotification.isEmpty) return;
    if (firestoreNotification.first.read) return;

    // Optimistic: patayin agad ang ilaw.
    _readFirestoreIds.add(notificationId);
    _refreshVisibleListeners();

    final uid = _currentUid;
    if (uid == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .doc(notificationId)
          .update({'read': true});
    } catch (e) {
      error.value = 'Unable to mark notification as read: $e';
    }
  }

  Future<void> markAllRead() async {
    // 1) Sensor events: tandaan ang kasalukuyang event ng bawat id bilang
    //    nabasa. Ang BAGONG event (iba ang signature) ay iilaw pa rin.
    for (final entry in _sensorEvents.entries.toList()) {
      _readSensorSignatures[entry.key] = _signatureFor(entry.value);
      _sensorEvents[entry.key] = entry.value.copyWith(read: true);
    }

    // 2) Firestore notifications: optimistic local update muna.
    final unreadFirestore = all.value
        .where(
          (n) =>
              !n.read &&
              !n.fromSensorEvents &&
              !_readFirestoreIds.contains(n.id) &&
              _registeredDeviceIds.contains(n.deviceId),
        )
        .toList();

    for (final notification in unreadFirestore) {
      _readFirestoreIds.add(notification.id);
    }

    // Patayin agad ang lahat ng ilaw sa UI at ang mga tray notification.
    _refreshVisibleListeners();
    LocalAlertService.instance.clearAll();

    // 3) I-save sa Firestore.
    final uid = _currentUid;

    if (uid != null && unreadFirestore.isNotEmpty) {
      final batch = _firestore.batch();

      for (final notification in unreadFirestore) {
        batch.update(
          _firestore
              .collection('users')
              .doc(uid)
              .collection('notifications')
              .doc(notification.id),
          {'read': true},
        );
      }

      try {
        await batch.commit();
      } catch (e) {
        error.value = 'Unable to mark all as read: $e';
      }
    }
  }

  // ==============================================================
  // DELETE NOTIFICATIONS
  // ==============================================================

  Future<void> deleteNotification(MotoNotification notification) async {
    final uid = _currentUid;
    if (uid == null) throw StateError('No signed-in user.');

    if (notification.fromSensorEvents) {
      // ID format is "$deviceId:$eventId".
      final prefix = '${notification.deviceId}:';
      final eventId = notification.id.startsWith(prefix)
          ? notification.id.substring(prefix.length)
          : '';

      if (eventId.isEmpty) {
        throw StateError('Invalid sensor event ID.');
      }

      final path = eventId == 'current_sensor_data'
          ? 'sensorEvents/${notification.deviceId}'
          : 'sensorEvents/${notification.deviceId}/$eventId';

      await _database.ref(path).remove();
      _sensorEvents.remove(notification.id);
      _readSensorSignatures.remove(notification.id);
      _notified.remove(notification.id);
    } else {
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .doc(notification.id)
          .delete();

      _readFirestoreIds.remove(notification.id);
      all.value = all.value.where((n) => n.id != notification.id).toList();
    }

    _refreshVisibleListeners();
  }

  Future<void> deleteNotifications(List<MotoNotification> notifications) async {
    for (final notification in notifications) {
      await deleteNotification(notification);
    }
  }

  // ==============================================================
  // CLEANUP
  // ==============================================================

  Future<void> _stopUserListeners() async {
    await _deviceSub?.cancel();
    await _notificationSub?.cancel();

    _deviceSub = null;
    _notificationSub = null;

    for (final sub in _statusSubs.values) {
      await sub.cancel();
    }

    for (final sub in _eventSubs.values) {
      await sub.cancel();
    }

    _statusSubs.clear();
    _eventSubs.clear();
    _sensorEvents.clear();
    _readSensorSignatures.clear();
    _readFirestoreIds.clear();
    _registeredDeviceIds.clear();
    _seen.clear();
    _notified.clear();
    _baselineDone.clear();

    devices.value = [];
    statuses.value = {};
    all.value = [];
    _started = false;
  }

  /// Call this on sign out so the next user starts clean.
  Future<void> stop() async {
    await _stopUserListeners();
    _currentUid = null;
    loaded.value = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopUserListeners();
    devices.dispose();
    statuses.dispose();
    all.dispose();
    loaded.dispose();
    error.dispose();
    super.dispose();
  }
}

// ================================================================
// PALETTE
// ================================================================

class MgPalette {
  final bool isDarkMode;

  const MgPalette(this.isDarkMode);

  Color get background =>
      isDarkMode ? const Color(0xFF0A0E17) : const Color(0xFFEDF1F6);

  Color get surface => isDarkMode ? const Color(0xFF121826) : Colors.white;

  Color get text =>
      isDarkMode ? const Color(0xFFF4F6F9) : const Color(0xFF11151E);

  Color get muted =>
      isDarkMode ? const Color(0xFF8A93A6) : const Color(0xFF5B6472);

  Color get green =>
      isDarkMode ? const Color(0xFF00E5C7) : const Color(0xFF00A88F);

  Color get border =>
      isDarkMode ? const Color(0xFF2A3346) : const Color(0xFFD3DAE3);
}

// ================================================================
// NOTIFICATION TILE
// ================================================================

class NotificationTile extends StatelessWidget {
  final MotoNotification n;
  final MgPalette p;
  final bool compact;
  final VoidCallback? onTap;

  const NotificationTile({
    super.key,
    required this.n,
    required this.p,
    this.compact = false,
    this.onTap,
  });

  bool get _isAccident {
    final type = n.type.toUpperCase();
    return type.contains('ACCIDENT') ||
        type.contains('EMERGENCY') ||
        type.contains('LEVEL2');
  }

  bool get _isSuspicious {
    final type = n.type.toUpperCase();
    return type.contains('MOVEMENT') ||
        type.contains('SUSPICIOUS') ||
        type.contains('LEVEL1');
  }

  IconData get _icon {
    if (_isAccident) return Icons.warning_amber_rounded;
    if (_isSuspicious) return Icons.sensors_rounded;
    return Icons.notifications_active_outlined;
  }

  Color get _iconColor {
    if (_isAccident) return Colors.redAccent;
    if (_isSuspicious) return Colors.orangeAccent;
    return p.green;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: EdgeInsets.only(bottom: compact ? 8 : 12),
        padding: EdgeInsets.all(compact ? 12 : 16),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: n.read ? p.border : p.green.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_icon, color: _iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.title,
                    style: GoogleFonts.inter(
                      color: p.text,
                      fontSize: 14,
                      fontWeight: n.read ? FontWeight.w500 : FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    n.message,
                    maxLines: compact ? 2 : null,
                    overflow: compact ? TextOverflow.ellipsis : null,
                    style: GoogleFonts.inter(
                      color: p.muted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 7),
                  // Kapag nabasa na, itinatago ang timestamp.
                  Text(
                    n.read
                        ? n.deviceId
                        : '${n.deviceId} • ${formatPhilippineTime(n.timestamp)}',
                    style: GoogleFonts.inter(
                      color: p.muted,
                      fontSize: 10,
                    ),
                  ),
                  if (n.latitude != null && n.longitude != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      'GPS: ${n.latitude}, ${n.longitude}',
                      style: GoogleFonts.inter(
                        color: p.green,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!n.read)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(left: 8, top: 5),
                decoration: BoxDecoration(
                  color: p.green,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// NOTIFICATION PAGE
// ================================================================

class NotificationPage extends StatefulWidget {
  final bool isDarkMode;

  /// Ikabit sa parent screen para maipakita ang selected event sa map.
  final ValueChanged<MotoNotification>? onGoToMap;

  const NotificationPage({
    super.key,
    this.isDarkMode = true,
    this.onGoToMap,
  });

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  final NotificationService _service = NotificationService.instance;

  late MgPalette _palette;
  final Set<String> _selectedIds = <String>{};
  bool _selectMode = false;
  bool _busy = false;

  Future<void> _confirmDelete(List<MotoNotification> items) async {
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(items.length == 1
            ? 'Delete notification?'
            : 'Delete notifications?'),
        content: Text(items.length == 1
            ? 'Permanenteng mabubura ang notification na ito sa Firebase.'
            : 'Permanenteng mabubura ang ${items.length} notifications sa Firebase.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await _service.deleteNotifications(items);
      if (!mounted) return;
      setState(() {
        _selectedIds.clear();
        _selectMode = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification deleted from Firebase.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hindi mabura ang notification: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openNotification(MotoNotification notification) async {
    await _service.markRead(notification.id);
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _palette.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(22),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                notification.title,
                style: TextStyle(
                  color: _palette.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                notification.message,
                style: TextStyle(color: _palette.muted),
              ),
              const SizedBox(height: 10),
              Text(
                '${notification.deviceId} • '
                '${formatPhilippineTime(notification.timestamp)}',
                style: TextStyle(
                  color: _palette.muted,
                  fontSize: 12,
                ),
              ),
              if (notification.latitude != null &&
                  notification.longitude != null) ...[
                const SizedBox(height: 8),
                Text(
                  'GPS: ${notification.latitude}, '
                  '${notification.longitude}',
                  style: TextStyle(
                    color: _palette.green,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 18),

              // GO TO MAP
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    // Isara ang notification details.
                    Navigator.pop(sheetContext);

                    // Kung ang parent screen ang humahawak ng map
                    // navigation, hayaan siya.
                    if (widget.onGoToMap != null) {
                      widget.onGoToMap!(notification);
                      return;
                    }

                    // Kung wala, buksan ang map page direkta.
                    // TODO: palitan ang `MapPage` ng TUNAY na pangalan
                    // ng class sa map.dart (walang `const`).
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MapPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Go to Map'),
                ),
              ),

              const SizedBox(height: 8),

              // DELETE NOTIFICATION
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _confirmDelete([notification]);
                  },
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.red,
                  ),
                  label: const Text(
                    'Delete Notification',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _palette = MgPalette(widget.isDarkMode);
    _service.start();
  }

  @override
  void didUpdateWidget(covariant NotificationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isDarkMode != widget.isDarkMode) {
      _palette = MgPalette(widget.isDarkMode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _service.changes,
      builder: (context, _) {
        final notifications = _service.visible;

        return Scaffold(
          backgroundColor: _palette.background,
          appBar: AppBar(
            backgroundColor: _palette.background,
            foregroundColor: _palette.text,
            elevation: 0,
            title: Text(
              'Notifications',
              style: GoogleFonts.inter(fontWeight: FontWeight.w700),
            ),
            actions: [
              if (_selectMode)
                TextButton(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => _confirmDelete(_service.visible
                          .where((n) => _selectedIds.contains(n.id))
                          .toList()),
                  child: Text('Delete (${_selectedIds.length})',
                      style: const TextStyle(color: Colors.red)),
                )
              else ...[
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'select') {
                      setState(() => _selectMode = true);
                    } else if (value == 'delete_all') {
                      _confirmDelete(_service.visible);
                    } else if (value == 'read_all') {
                      _service.markAllRead();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                        value: 'select', child: Text('Select notifications')),
                    PopupMenuItem(
                        value: 'delete_all', child: Text('Delete All')),
                    PopupMenuItem(
                        value: 'read_all', child: Text('Mark all read')),
                  ],
                ),
              ],
              if (_selectMode)
                TextButton(
                  onPressed: () => setState(() {
                    _selectMode = false;
                    _selectedIds.clear();
                  }),
                  child: const Text('Cancel'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(child: _buildBody(notifications)),
        );
      },
    );
  }

  Widget _stateMessage(IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _palette.muted, size: 48),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                color: _palette.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: _palette.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(List<MotoNotification> notifications) {
    if (_service.error.value != null && _service.devices.value.isEmpty) {
      return _stateMessage(
        Icons.error_outline_rounded,
        'Something went wrong',
        _service.error.value!,
      );
    }

    if (!_service.loaded.value && _service.devices.value.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: _palette.green),
      );
    }

    if (_service.devices.value.isEmpty) {
      return _stateMessage(
        Icons.devices_other_rounded,
        'No registered devices found',
        'Register or connect your MotoGuard device to see its notifications.',
      );
    }

    if (notifications.isEmpty) {
      return _stateMessage(
        Icons.notifications_none_rounded,
        'No notifications yet',
        'Sensor events from your registered devices will appear here.',
      );
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'History',
                style: GoogleFonts.inter(
                  color: _palette.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${_service.unreadCount} unread',
              style: GoogleFonts.inter(
                color: _palette.muted,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (_selectMode)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() {
                if (_selectedIds.length == notifications.length) {
                  _selectedIds.clear();
                } else {
                  _selectedIds
                    ..clear()
                    ..addAll(notifications.map((n) => n.id));
                }
              }),
              child: Text(_selectedIds.length == notifications.length
                  ? 'Deselect all'
                  : 'Select all'),
            ),
          ),
        if (_busy) const LinearProgressIndicator(),
        for (final notification in notifications)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_selectMode)
                Checkbox(
                  value: _selectedIds.contains(notification.id),
                  activeColor: _palette.green,
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selectedIds.add(notification.id);
                    } else {
                      _selectedIds.remove(notification.id);
                    }
                  }),
                ),
              Expanded(
                child: NotificationTile(
                  n: notification,
                  p: _palette,
                  onTap: _selectMode
                      ? () => setState(() {
                            if (!_selectedIds.add(notification.id)) {
                              _selectedIds.remove(notification.id);
                            }
                          })
                      : () => _openNotification(notification),
                ),
              ),
            ],
          ),
      ],
    );
  }
}