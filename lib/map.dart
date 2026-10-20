import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpHeaders, SocketException;
import 'dart:ui' show ImageFilter;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

// my_device.dart now contains the passkey connection flow, the shared
// device registry, and kMotoRtdbUrl / kHeartbeatTimeoutMs /
// kClockToleranceMs / kReattachEveryMs.
import 'my_device.dart';

// ======================================================================
// CONFIGURATION
// ======================================================================

const int kMinSatellites = 4;

const bool kShowLastKnownWhenLost = true;
const bool kShowPhone = true;
const bool kShowDebugLine = false;

const LatLng kDefaultCenter = LatLng(14.5995, 120.9842);

// ======================================================================
// MAP SEARCH
// ======================================================================

const bool kShowLocationSearch = true;
const double kSearchZoom = 16;
const double kSearchMaxWidth = 600;
const String kSearchUserAgent = 'MotoGuardTracker/1.0 (com.example.tracker)';

// ======================================================================
// MOTORCYCLE
// ======================================================================

const double kFollowZoom = 17;

// ======================================================================
// THEME
// ======================================================================

const Color kBg = Color(0xFF0D1117);
const Color kPanel = Color(0xFF131925);
const Color kPanelHi = Color(0xFF1B2333);
const Color kAccent = Colors.orange;
const Color kBlue = Color(0xFF3B9BFF);

// ======================================================================
// HELPERS
// ======================================================================

double? _asDouble(Object? value) {
  if (value is num) {
    final d = value.toDouble();
    return d.isFinite ? d : null;
  }

  if (value is String) {
    final d = double.tryParse(value.trim());
    return d != null && d.isFinite ? d : null;
  }

  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is String) return value.trim().toLowerCase() == 'true';
  if (value is num) return value != 0;
  return false;
}

// ======================================================================
// GPS MODEL
// ======================================================================

class MotoGpsData {
  final double? latitude;
  final double? longitude;
  final double? altitude;
  final double? speedKmh;
  final double? accuracy;
  final double? hdop;
  final int? satellites;
  final bool gpsFix;
  final String status;
  final int? deviceTimestamp;
  final int? updatedAt;
  final int? seq;

  const MotoGpsData({
    this.latitude,
    this.longitude,
    this.altitude,
    this.speedKmh,
    this.accuracy,
    this.hdop,
    this.satellites,
    required this.gpsFix,
    required this.status,
    this.deviceTimestamp,
    this.updatedAt,
    this.seq,
  });

  factory MotoGpsData.fromMap(Map<Object?, Object?> map) {
    return MotoGpsData(
      latitude: _asDouble(map['latitude']),
      longitude: _asDouble(map['longitude']),
      altitude: _asDouble(map['altitude']),
      speedKmh: _asDouble(map['speed']),
      accuracy: _asDouble(map['accuracy']),
      hdop: _asDouble(map['hdop']),
      satellites: _asInt(map['satellites']),
      gpsFix: _asBool(map['gpsFix']),
      status: (map['status'] ?? 'UNKNOWN').toString(),
      deviceTimestamp: _asInt(map['deviceTimestamp']),
      updatedAt: _asInt(map['updatedAt']),
      seq: _asInt(map['seq']),
    );
  }

  bool get hasValidCoordinates {
    final lat = latitude;
    final lng = longitude;

    if (lat == null || lng == null) return false;
    if (lat < -90 || lat > 90) return false;
    if (lng < -180 || lng > 180) return false;
    if (lat == 0 && lng == 0) return false;

    return true;
  }

  LatLng? get position {
    if (!hasValidCoordinates) return null;
    return LatLng(latitude!, longitude!);
  }
}

// ======================================================================
// GPS HEALTH
// ======================================================================

enum GpsHealth {
  noDevice,
  waiting,
  online,
  gpsLost,
  stale,
  deviceOffline,
  firebaseOffline,
  firebaseError,
}

// ======================================================================
// SEARCH RESULT
// ======================================================================

class _SearchResult {
  final LatLng point;
  final String label;
  final String fullName;

  const _SearchResult(this.point, this.label, this.fullName);
}

// ======================================================================
// MAP PAGE
// ======================================================================

class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
  });

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with SingleTickerProviderStateMixin {
  // ====================================================================
  // FIREBASE
  // ====================================================================

  late final FirebaseDatabase _db;

  StreamSubscription<DatabaseEvent>? _gpsSub;
  StreamSubscription<DatabaseEvent>? _connSub;
  StreamSubscription<DatabaseEvent>? _offsetSub;

  bool _fbConnected = false;
  int _serverOffsetMs = 0;
  String? _dbError;

  // ====================================================================
  // REGISTERED DEVICE
  //
  // We NEVER listen to gps/*. We only listen to gps/<registered-id>.
  // ====================================================================

  final MotoDeviceRegistry _registry = MotoDeviceRegistry.instance;

  String? _deviceId;
  String _deviceName = '';

  bool _loadingDevice = true;
  String? _deviceError;

  // ====================================================================
  // AUTO RECONNECT
  // ====================================================================

  int _lastReattachMs = 0;

  // ====================================================================
  // SEARCH
  // ====================================================================

  final TextEditingController _searchCtrl = TextEditingController();

  bool _searching = false;

  LatLng? _searchPos;
  String? _searchLabel;

  // ====================================================================
  // MOTORCYCLE GPS
  // ====================================================================

  MotoGpsData? _data;

  int? _lastSeq;
  int? _lastUpdatedAt;

  final Stopwatch _clock = Stopwatch()..start();

  int _lastChangeMs = 0;

  // ====================================================================
  // PHONE GPS
  // ====================================================================

  StreamSubscription<Position>? _phoneSub;

  LatLng? _phoneLocation;
  double? _phoneAccuracy;

  String _phoneStatus = 'Starting phone GPS...';

  // ====================================================================
  // MAP
  // ====================================================================

  final MapController _mapController = MapController();

  bool _mapReady = false;
  bool _follow = true;
  bool _showDetails = false;

  // ====================================================================
  // MARKER ANIMATION
  // ====================================================================

  late final AnimationController _anim;

  final ValueNotifier<LatLng?> _markerPos = ValueNotifier<LatLng?>(null);

  LatLng? _animFrom;
  LatLng? _animTo;

  Timer? _ticker;

  // ====================================================================
  // INIT
  // ====================================================================

  @override
  void initState() {
    super.initState();

    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addListener(_onAnimTick);

    _db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: kMotoRtdbUrl,
    );

    // Firebase connection
    _connSub = _db.ref('.info/connected').onValue.listen(
      (event) {
        if (!mounted) return;

        setState(() {
          _fbConnected = event.snapshot.value == true;
        });
      },
      onError: (Object error) {
        if (!mounted) return;

        setState(() {
          _dbError = error.toString();
        });
      },
    );

    // Firebase server time
    _offsetSub = _db.ref('.info/serverTimeOffset').onValue.listen(
      (event) {
        final value = event.snapshot.value;

        if (value is num) {
          _serverOffsetMs = value.toInt();
        }
      },
      onError: (Object _) {},
    );

    // Health refresh + automatic reconnect
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;

        _autoReconnect();

        setState(() {});
      },
    );

    // Phone GPS
    _startPhoneGps();

    // Registered device
    _registry.retain();
    _registry.state.addListener(_onRegistryChanged);
    _onRegistryChanged();
  }

  // ====================================================================
  // DISPOSE
  // ====================================================================

  @override
  void dispose() {
    _registry.state.removeListener(_onRegistryChanged);
    _registry.release();

    _gpsSub?.cancel();
    _connSub?.cancel();
    _offsetSub?.cancel();
    _phoneSub?.cancel();

    _ticker?.cancel();

    _searchCtrl.dispose();

    _anim.dispose();
    _markerPos.dispose();

    _mapController.dispose();

    super.dispose();
  }

  // ====================================================================
  // DEVICE REGISTRY
  // ====================================================================

  void _onRegistryChanged() {
    if (!mounted) return;

    final state = _registry.state.value;

    if (state.loading) {
      setState(() {
        _loadingDevice = true;
      });

      return;
    }

    if (state.error != null && state.device == null) {
      _removeGpsListener();

      setState(() {
        _loadingDevice = false;
        _deviceError = state.error;
        _deviceId = null;
        _deviceName = '';
        _data = null;
        _markerPos.value = null;
      });

      return;
    }

    _applyDevice(
      state.device?.id,
      state.device?.name,
    );
  }

  void _removeGpsListener() {
    _gpsSub?.cancel();
    _gpsSub = null;
  }

  // ====================================================================
  // SUBSCRIBE TO gps/<deviceId>  (also used for reconnecting)
  // ====================================================================

  void _subscribeGps(String safeId) {
    _removeGpsListener();

    _lastReattachMs = _clock.elapsedMilliseconds;

    _gpsSub = _db.ref('gps/$safeId').onValue.listen(
      _onGpsEvent,
      onError: (Object error) {
        if (!mounted) return;

        setState(() {
          _dbError = error.toString();
        });
      },
    );
  }

  // ====================================================================
  // AUTO RECONNECT
  //
  // If the ESP32 / database stream goes quiet or errors out, re-open
  // the Firebase connection and re-attach the listener every
  // kReattachEveryMs until data flows again.
  // ====================================================================

  void _autoReconnect() {
    final id = _deviceId;

    if (id == null || id.trim().isEmpty) return;

    final health = _evaluate();

    final needsReconnect = health == GpsHealth.deviceOffline ||
        health == GpsHealth.waiting ||
        health == GpsHealth.firebaseError ||
        health == GpsHealth.firebaseOffline;

    if (!needsReconnect) return;

    final now = _clock.elapsedMilliseconds;

    if (now - _lastReattachMs < kReattachEveryMs) return;

    _db.goOnline();

    _subscribeGps(id.trim());
  }

  // ====================================================================
  // APPLY DEVICE
  // ====================================================================

  void _applyDevice(
    String? id,
    String? name,
  ) {
    if (!mounted) return;

    // Same device
    if (id == _deviceId) {
      setState(() {
        _deviceName = name ?? '';
        _loadingDevice = false;
        _deviceError = null;
      });

      return;
    }

    // Device changed or removed
    _removeGpsListener();

    _anim.stop();

    _animFrom = null;
    _animTo = null;

    _lastSeq = null;
    _lastUpdatedAt = null;

    _lastChangeMs = _clock.elapsedMilliseconds;

    _markerPos.value = null;

    _data = null;

    setState(() {
      _deviceId = id;
      _deviceName = name ?? '';

      _loadingDevice = false;
      _deviceError = null;
      _dbError = null;

      _follow = true;
    });

    // No completed registration: no GPS listener, no marker.
    if (id == null || id.trim().isEmpty) {
      return;
    }

    _subscribeGps(id.trim());
  }

  // ====================================================================
  // REGISTRATION / MY DEVICE PAGE
  //
  // MyDevicePage now handles BOTH: entering the passkey (no device) and
  // showing the live ESP32 status (device registered).
  // ====================================================================

  Future<void> _openRegistration() async {
    FocusScope.of(context).unfocus();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const MyDevicePage(),
      ),
    );

    // MotoDeviceRegistry notifies us automatically after any change.
  }

  // ====================================================================
  // MESSAGE
  // ====================================================================

  void _showMessage(String message) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);

    messenger.hideCurrentSnackBar();

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.manrope(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: kPanelHi,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ====================================================================
  // SEARCH
  // ====================================================================

  LatLng? _parseCoordinates(String query) {
    final match = RegExp(
      r'^\s*(-?\d+(?:\.\d+)?)\s*[,;\s]\s*(-?\d+(?:\.\d+)?)\s*$',
    ).firstMatch(query);

    if (match == null) return null;

    final lat = double.tryParse(match.group(1)!);
    final lng = double.tryParse(match.group(2)!);

    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90) return null;
    if (lng < -180 || lng > 180) return null;

    return LatLng(lat, lng);
  }

  Future<_SearchResult?> _geocode(String query) async {
    final uri = Uri.https(
      'nominatim.openstreetmap.org',
      '/search',
      {
        'q': query,
        'format': 'jsonv2',
        'limit': '1',
        'addressdetails': '0',
      },
    );

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client.getUrl(uri).timeout(
            const Duration(seconds: 10),
          );

      request.headers.set(HttpHeaders.userAgentHeader, kSearchUserAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final body = await response.transform(utf8.decoder).join().timeout(
            const Duration(seconds: 10),
          );

      final decoded = jsonDecode(body);

      if (decoded is! List || decoded.isEmpty) return null;

      final first = decoded.first;

      if (first is! Map) return null;

      final lat = _asDouble(first['lat']);
      final lon = _asDouble(first['lon']);

      if (lat == null || lon == null) return null;
      if (lat < -90 || lat > 90) return null;
      if (lon < -180 || lon > 180) return null;

      final full = (first['display_name'] ?? query).toString();

      var label = full.split(',').first.trim();

      if (label.isEmpty) {
        label = query;
      }

      return _SearchResult(LatLng(lat, lon), label, full);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _searchLocation(String input) async {
    final query = input.trim();

    if (query.isEmpty || _searching) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _searching = true;
    });

    try {
      final coords = _parseCoordinates(query);

      final _SearchResult? result = coords != null
          ? _SearchResult(
              coords,
              '${coords.latitude.toStringAsFixed(5)}, '
              '${coords.longitude.toStringAsFixed(5)}',
              query,
            )
          : await _geocode(query);

      if (!mounted) return;

      if (result == null) {
        _showMessage('Location not found.');
        return;
      }

      setState(() {
        _searchPos = result.point;
        _searchLabel = result.label;

        _follow = false;
      });

      if (_mapReady) {
        _mapController.move(result.point, kSearchZoom);
      }
    } on TimeoutException {
      _showMessage('Search timed out. Please try again.');
    } on SocketException {
      _showMessage('No internet connection.');
    } catch (_) {
      _showMessage('Location search is unavailable right now.');
    } finally {
      if (mounted) {
        setState(() {
          _searching = false;
        });
      }
    }
  }

  void _clearSearch() {
    _searchCtrl.clear();

    setState(() {
      _searchPos = null;
      _searchLabel = null;
    });
  }

  // ====================================================================
  // PHONE GPS
  // ====================================================================

  void _setPhoneStatus(String status) {
    if (!mounted) return;

    setState(() {
      _phoneStatus = status;
    });
  }

  Future<void> _startPhoneGps() async {
    if (!kShowPhone) return;

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        _setPhoneStatus('Phone location services disabled');
        return;
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setPhoneStatus('Phone location permission denied');
        return;
      }

      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      );

      _phoneSub = Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen(
        (position) {
          if (!mounted) return;

          setState(() {
            _phoneLocation = LatLng(position.latitude, position.longitude);
            _phoneAccuracy = position.accuracy;

            _phoneStatus = 'Phone GPS OK '
                '(±${position.accuracy.toStringAsFixed(0)} m)';
          });
        },
        onError: (Object error) {
          _setPhoneStatus('Phone GPS error: $error');
        },
      );
    } catch (e) {
      _setPhoneStatus('Phone GPS error: $e');
    }
  }

  void _centerOnPhone() {
    final phone = _phoneLocation;

    if (phone == null) {
      _showMessage('Phone location is not available yet.');
      return;
    }

    setState(() {
      _follow = false;
    });

    if (_mapReady) {
      _mapController.move(phone, kFollowZoom);
    }
  }

  // ====================================================================
  // MOTORCYCLE GPS EVENT
  // ====================================================================

  void _onGpsEvent(DatabaseEvent event) {
    if (!mounted) return;

    if (_deviceId == null || _deviceId!.trim().isEmpty) {
      return;
    }

    final value = event.snapshot.value;

    if (value is! Map) {
      setState(() {
        _data = null;
        _dbError = null;
      });

      return;
    }

    final MotoGpsData data;

    try {
      data = MotoGpsData.fromMap(
        Map<Object?, Object?>.from(value),
      );
    } catch (e) {
      setState(() {
        _dbError = 'Bad data format: $e';
      });

      return;
    }

    if (_data == null ||
        data.seq != _lastSeq ||
        data.updatedAt != _lastUpdatedAt) {
      _lastSeq = data.seq;
      _lastUpdatedAt = data.updatedAt;

      _lastChangeMs = _clock.elapsedMilliseconds;
    }

    setState(() {
      _data = data;
      _dbError = null;
    });

    if (_evaluate() == GpsHealth.online) {
      final position = data.position;

      if (position != null) {
        _moveMarkerTo(position);
      }
    }
  }

  // ====================================================================
  // TIME
  // ====================================================================

  int _serverNowMs() {
    return DateTime.now().millisecondsSinceEpoch + _serverOffsetMs;
  }

  int? _serverAgeMs() {
    final updatedAt = _data?.updatedAt;

    if (updatedAt == null) return null;

    return _serverNowMs() - updatedAt;
  }

  // ====================================================================
  // GPS HEALTH
  // ====================================================================

  GpsHealth _evaluate() {
    if (_deviceError != null || _dbError != null) {
      return GpsHealth.firebaseError;
    }

    if (_deviceId == null || _deviceId!.trim().isEmpty) {
      return GpsHealth.noDevice;
    }

    if (!_fbConnected) {
      return GpsHealth.firebaseOffline;
    }

    final data = _data;

    if (data == null) {
      return GpsHealth.waiting;
    }

    final silenceMs = _clock.elapsedMilliseconds - _lastChangeMs;

    final serverAge = _serverAgeMs();

    if (serverAge == null ||
        serverAge < -kClockToleranceMs ||
        serverAge > kHeartbeatTimeoutMs ||
        silenceMs > kHeartbeatTimeoutMs) {
      return GpsHealth.deviceOffline;
    }

    if (!data.gpsFix || data.status != 'GPS_ONLINE') {
      return GpsHealth.gpsLost;
    }

    final satellites = data.satellites ?? 0;
    final deviceTimestamp = data.deviceTimestamp;
    final updatedAt = data.updatedAt;

    if (deviceTimestamp == null || updatedAt == null) {
      return GpsHealth.stale;
    }

    final timestampDifference = (updatedAt - deviceTimestamp).abs();

    if (!data.hasValidCoordinates ||
        satellites < kMinSatellites ||
        timestampDifference > kClockToleranceMs) {
      return GpsHealth.stale;
    }

    return GpsHealth.online;
  }

  /// The ESP32 itself is reachable whenever its heartbeat is fresh,
  /// even if it has no GPS fix yet.
  bool _espReachable(GpsHealth health) {
    return health == GpsHealth.online ||
        health == GpsHealth.gpsLost ||
        health == GpsHealth.stale;
  }

  // ====================================================================
  // MARKER ANIMATION
  // ====================================================================

  void _moveMarkerTo(LatLng target) {
    final current = _markerPos.value;

    if (current == null) {
      _markerPos.value = target;

      _centerOn(target);

      return;
    }

    if (current.latitude == target.latitude &&
        current.longitude == target.longitude) {
      return;
    }

    final meters = const Distance().as(
      LengthUnit.Meter,
      current,
      target,
    );

    if (meters > 500) {
      _anim.stop();

      _markerPos.value = target;

      if (_follow) {
        _centerOn(target);
      }

      return;
    }

    _animFrom = current;
    _animTo = target;

    _anim.forward(from: 0);
  }

  void _onAnimTick() {
    final from = _animFrom;
    final to = _animTo;

    if (from == null || to == null) return;

    final t = _anim.value;

    final position = LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );

    _markerPos.value = position;

    if (_follow) {
      _centerOn(position);
    }
  }

  void _centerOn(LatLng position) {
    if (!_mapReady) return;

    _mapController.move(position, _mapController.camera.zoom);
  }

  void _followMotorcycle() {
    final position = _markerPos.value;

    if (position == null) {
      _showMessage(
        _deviceId == null
            ? 'Register your motorcycle first.'
            : 'Motorcycle location is not available yet.',
      );

      return;
    }

    setState(() {
      _follow = true;
    });

    if (_mapReady) {
      _mapController.move(position, kFollowZoom);
    }
  }

  // ====================================================================
  // FORMAT
  // ====================================================================

  String _fmtClock(int? milliseconds) {
    if (milliseconds == null) return '--:--:--';

    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();

    String two(int number) => number.toString().padLeft(2, '0');

    return '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  // ====================================================================
  // HEALTH LABEL
  // ====================================================================

  String _label(GpsHealth health) {
    switch (health) {
      case GpsHealth.online:
        return 'ESP32 CONNECTED';

      case GpsHealth.gpsLost:
        return 'ESP32 CONNECTED - NO GPS';

      case GpsHealth.stale:
        return 'STALE';

      case GpsHealth.deviceOffline:
        return 'ESP32 DISCONNECTED';

      case GpsHealth.firebaseOffline:
        return 'FIREBASE OFFLINE';

      case GpsHealth.firebaseError:
        return 'DATABASE ERROR';

      case GpsHealth.waiting:
        return 'WAITING FOR DATA';

      case GpsHealth.noDevice:
        return _loadingDevice ? 'LOADING...' : 'NO MOTORCYCLE';
    }
  }

  // ====================================================================
  // HEALTH MESSAGE
  // ====================================================================

  String _message(GpsHealth health) {
    switch (health) {
      case GpsHealth.online:
        return '';

      case GpsHealth.gpsLost:
        return 'Waiting for GPS signal...';

      case GpsHealth.stale:
        return 'GPS data is not fresh or not reliable.';

      case GpsHealth.deviceOffline:
        return 'No updates from the ESP32. Reconnecting...';

      case GpsHealth.firebaseOffline:
        return 'This phone is not connected to Firebase. Reconnecting...';

      case GpsHealth.firebaseError:
        return _deviceError ?? _dbError ?? 'Database error.';

      case GpsHealth.waiting:
        return 'Waiting for the ESP32 to send data...';

      case GpsHealth.noDevice:
        return _loadingDevice
            ? 'Loading your motorcycle...'
            : 'Register your motorcycle to start tracking.';
    }
  }

  // ====================================================================
  // HEALTH COLOR
  // ====================================================================

  Color _color(GpsHealth health) {
    switch (health) {
      case GpsHealth.online:
        return Colors.greenAccent;

      case GpsHealth.gpsLost:
      case GpsHealth.stale:
        return Colors.orangeAccent;

      case GpsHealth.deviceOffline:
      case GpsHealth.firebaseOffline:
      case GpsHealth.firebaseError:
        return Colors.redAccent;

      case GpsHealth.waiting:
      case GpsHealth.noDevice:
        return Colors.grey;
    }
  }

  // ====================================================================
  // PHONE -> MOTORCYCLE DISTANCE
  // ====================================================================

  String? _distanceText(GpsHealth health) {
    final phone = _phoneLocation;

    final motorcycle = _markerPos.value;

    if (!kShowPhone || phone == null || motorcycle == null) {
      return null;
    }

    if (health != GpsHealth.online) {
      return null;
    }

    const distance = Distance();

    final meters = distance.as(LengthUnit.Meter, phone, motorcycle);

    final bearing = (distance.bearing(phone, motorcycle) + 360) % 360;

    final text = meters < 1000
        ? '${meters.toStringAsFixed(0)} m'
        : '${(meters / 1000).toStringAsFixed(2)} km';

    return '$text  •  ${bearing.toStringAsFixed(0)}°';
  }

  // ====================================================================
  // BUILD
  // ====================================================================

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;

    final hasDevice = _deviceId != null && _deviceId!.trim().isNotEmpty;

    final health = _evaluate();
    final distanceText = _distanceText(health);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: kBg,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            // MAP
            Positioned.fill(
              child: _buildMap(),
            ),

            // SOFT TOP FADE (keeps the floating bar readable on any tile)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: padding.top + 120,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.28),
                        Colors.black.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // MAP CREDIT
            Positioned(
              left: 0,
              right: 0,
              bottom: padding.bottom + 3,
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    '© OpenStreetMap contributors',
                    style: GoogleFonts.manrope(
                      color: Colors.black54,
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),

            // TOP BAR
            Positioned(
              top: padding.top + 8,
              left: 12 + padding.left,
              right: 12 + padding.right,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: kSearchMaxWidth,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          _MapButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: 'Back',
                            size: 48,
                            onTap: () => Navigator.pop(context),
                          ),
                          if (kShowLocationSearch) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildSearchBar(),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _buildStatusPanel(),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // DISTANCE CHIP (phone -> motorcycle)
            if (distanceText != null)
              Positioned(
                left: 76 + padding.left,
                right: 76 + padding.right,
                bottom: padding.bottom + 24,
                child: IgnorePointer(
                  child: Center(
                    child: _DistanceChip(text: distanceText),
                  ),
                ),
              ),

            // PASSKEY / DEVICE
            if (!_loadingDevice)
              Positioned(
                left: 12 + padding.left,
                bottom: padding.bottom + 18,
                child: hasDevice
                    ? _MapButton(
                        icon: Icons.vpn_key_rounded,
                        tooltip: 'My device',
                        onTap: _openRegistration,
                      )
                    : _RegisterPill(
                        onTap: _openRegistration,
                      ),
              ),

            // ACTION BUTTONS
            Positioned(
              right: 12 + padding.right,
              bottom: padding.bottom + 18,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (kShowPhone) ...[
                    _MapButton(
                      icon: Icons.my_location_rounded,
                      tooltip: 'My location',
                      disabled: _phoneLocation == null,
                      onTap: _centerOnPhone,
                    ),
                    const SizedBox(height: 10),
                  ],
                  _MapButton(
                    icon: _follow
                        ? Icons.motorcycle_rounded
                        : Icons.gps_not_fixed_rounded,
                    tooltip: 'Follow motorcycle',
                    primary: true,
                    active: _follow && hasDevice,
                    disabled: !hasDevice,
                    size: 56,
                    onTap: _followMotorcycle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ====================================================================
  // MAP
  // ====================================================================

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _markerPos.value ?? kDefaultCenter,
        initialZoom: 16,
        onMapReady: () {
          _mapReady = true;

          final position = _markerPos.value;

          if (position != null) {
            _centerOn(position);
          }
        },
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && _follow) {
            setState(() {
              _follow = false;
            });
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.tracker',
        ),

        // PHONE ACCURACY HALO
        if (kShowPhone && _phoneLocation != null && (_phoneAccuracy ?? 0) > 8)
          CircleLayer(
            circles: [
              CircleMarker(
                point: _phoneLocation!,
                radius: _phoneAccuracy!,
                useRadiusInMeter: true,
                color: kBlue.withValues(alpha: 0.12),
                borderColor: kBlue.withValues(alpha: 0.35),
                borderStrokeWidth: 1,
              ),
            ],
          ),

        ValueListenableBuilder<LatLng?>(
          valueListenable: _markerPos,
          builder: (context, position, _) {
            final health = _evaluate();

            final live = health == GpsHealth.online;

            final showMotorcycle =
                position != null && (live || kShowLastKnownWhenLost);

            final phone = _phoneLocation;

            final search = _searchPos;

            return MarkerLayer(
              markers: [
                if (search != null)
                  Marker(
                    point: search,
                    width: 150,
                    height: 76,
                    alignment: Alignment.topCenter,
                    child: _SearchMarker(
                      label: _searchLabel ?? '',
                    ),
                  ),

                // PHONE = BLUE DOT
                if (kShowPhone && phone != null)
                  Marker(
                    point: phone,
                    width: 52,
                    height: 52,
                    child: const _PhoneDot(),
                  ),

                if (showMotorcycle)
                  Marker(
                    point: position,
                    width: 104,
                    height: 104,
                    child: _MotorcycleMarker(
                      live: live,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  // ====================================================================
  // SEARCH BAR
  // ====================================================================

  Widget _buildSearchBar() {
    final hasText = _searchCtrl.text.isNotEmpty;

    return _Glass(
      radius: 24,
      borderColor: Colors.white,
      child: SizedBox(
        height: 48,
        child: TextField(
          controller: _searchCtrl,
          textInputAction: TextInputAction.search,
          onSubmitted: _searchLocation,
          onChanged: (_) {
            setState(() {});
          },
          style: GoogleFonts.manrope(
            color: Colors.white,
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
          cursorColor: kAccent,
          decoration: InputDecoration(
            hintText: 'Search places or lat, lng',
            hintStyle: GoogleFonts.manrope(
              color: Colors.white54,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            prefixIcon: IconButton(
              icon: const Icon(Icons.search_rounded, color: kAccent),
              tooltip: 'Search',
              onPressed: () => _searchLocation(_searchCtrl.text),
            ),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kAccent,
                      ),
                    ),
                  )
                : hasText
                    ? IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                        ),
                        tooltip: 'Clear',
                        onPressed: _clearSearch,
                      )
                    : null,
          ),
        ),
      ),
    );
  }

  // ====================================================================
  // STATUS PANEL
  // ====================================================================

  Widget _buildStatusPanel() {
    final health = _evaluate();

    final data = _data;

    final online = health == GpsHealth.online;

    final color = _color(health);

    final distanceText = _distanceText(health);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _showDetails = !_showDetails;
        });
      },
      child: _Glass(
        borderColor: color,
        radius: 22,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          alignment: Alignment.topLeft,
          curve: Curves.easeOutCubic,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: 0,
                maxWidth: _showDetails ? kSearchMaxWidth : 300,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.7),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _label(health),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.manrope(
                            color: color,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      if (online && data?.speedKmh != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${data!.speedKmh!.toStringAsFixed(0)} km/h',
                            style: GoogleFonts.manrope(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      Icon(
                        _showDetails
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: Colors.white54,
                        size: 20,
                      ),
                    ],
                  ),

                  // Compact message
                  if (!online && !_showDetails) ...[
                    const SizedBox(height: 4),
                    Text(
                      _message(health),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.manrope(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],

                  // DETAILS
                  if (_showDetails) ...[
                    if (!online) ...[
                      const SizedBox(height: 5),
                      Text(
                        _message(health),
                        style: GoogleFonts.manrope(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    const SizedBox(height: 8),
                    _row(
                      'ESP32',
                      _deviceId == null
                          ? '--'
                          : (_espReachable(health)
                              ? 'Connected'
                              : 'Disconnected (reconnecting)'),
                      valueColor: _deviceId == null
                          ? null
                          : (_espReachable(health)
                              ? Colors.greenAccent
                              : Colors.redAccent),
                    ),
                    _row(
                      'Motorcycle',
                      _deviceName.isEmpty ? '--' : _deviceName,
                    ),
                    _row('Device ID', _deviceId ?? '--'),
                    _row(
                      'Satellites',
                      data?.satellites?.toString() ?? '--',
                    ),
                    _row(
                      'Accuracy',
                      online && data?.accuracy != null
                          ? '${data!.accuracy!.toStringAsFixed(1)} m'
                              '${data.hdop != null ? '  (HDOP ${data.hdop!.toStringAsFixed(2)})' : ''}'
                          : '--',
                    ),
                    _row(
                      'Speed',
                      online && data?.speedKmh != null
                          ? '${data!.speedKmh!.toStringAsFixed(1)} km/h'
                          : '--',
                    ),
                    _row('Last Update', _fmtClock(data?.updatedAt)),
                    if (!online && data?.deviceTimestamp != null)
                      _row('Last GPS fix', _fmtClock(data!.deviceTimestamp)),
                    if (kShowPhone) ...[
                      _row('Phone → Moto', distanceText ?? '--'),
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          _phoneStatus,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.manrope(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                    if (kShowDebugLine)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _debugText(),
                          style: GoogleFonts.manrope(
                            color: Colors.white38,
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ====================================================================
  // DEBUG  (never prints the passkey)
  // ====================================================================

  String _debugText() {
    final data = _data;

    if (data == null) {
      return 'fb=${_fbConnected ? "connected" : "offline"}  '
          'device=${_deviceId ?? "none"}  '
          'no data';
    }

    final age = _serverAgeMs();

    final diff = data.updatedAt != null && data.deviceTimestamp != null
        ? ((data.updatedAt! - data.deviceTimestamp!) / 1000).toStringAsFixed(1)
        : '?';

    final silence = ((_clock.elapsedMilliseconds - _lastChangeMs) / 1000)
        .toStringAsFixed(1);

    return 'fb=${_fbConnected ? "connected" : "offline"}  '
        'device=${_deviceId ?? "none"}  '
        'seq=${data.seq ?? "?"}  '
        'serverAge=${age == null ? "?" : (age / 1000).toStringAsFixed(1)}s  '
        'noNewData=${silence}s  '
        'gpsVsServer=${diff}s  '
        'status=${data.status}  '
        'fix=${data.gpsFix}';
  }

  // ====================================================================
  // ROW
  // ====================================================================

  Widget _row(
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: GoogleFonts.manrope(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.manrope(
                color: valueColor ?? Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ======================================================================
// PULSE (animated expanding ring behind a marker)
// ======================================================================

class _Pulse extends StatefulWidget {
  final Color color;
  final double size;
  final bool active;
  final Widget child;

  const _Pulse({
    required this.color,
    required this.size,
    required this.child,
    this.active = true,
  });

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  @override
  void initState() {
    super.initState();

    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _Pulse oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.active)
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final t = _c.value;
                final d = widget.size * (0.40 + 0.60 * t);

                return Container(
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: (1 - t) * 0.35),
                  ),
                );
              },
            ),
          widget.child,
        ],
      ),
    );
  }
}

// ======================================================================
// MAP BUTTON
// ======================================================================

class _MapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  final bool active;
  final bool primary;
  final bool disabled;

  final double size;

  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.primary = false,
    this.disabled = false,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    final highlighted = (primary || active) && !disabled;

    final iconColor = highlighted ? Colors.black : kAccent;

    BoxDecoration decoration;

    if (disabled) {
      decoration = BoxDecoration(
        shape: BoxShape.circle,
        color: kPanel.withValues(alpha: 0.80),
        border: Border.all(color: Colors.white10),
      );
    } else if (highlighted) {
      decoration = const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFFFFB347), Color(0xFFFF6B1A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x66FF9800),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      );
    } else {
      decoration = BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            kPanelHi.withValues(alpha: 0.96),
            kPanel.withValues(alpha: 0.96),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      );
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          width: size,
          height: size,
          decoration: decoration,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: disabled ? null : onTap,
            child: Center(
              child: Icon(
                icon,
                color: disabled ? Colors.white30 : iconColor,
                size: primary ? 26 : 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// REGISTER PASSKEY PILL
// ======================================================================

class _RegisterPill extends StatelessWidget {
  final VoidCallback onTap;

  const _RegisterPill({
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        height: 50,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: const LinearGradient(
            colors: [Color(0xFFFFB347), Color(0xFFFF6B1A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66FF9800),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(25),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.vpn_key_rounded,
                  color: Colors.black,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Register Passkey',
                  style: GoogleFonts.manrope(
                    color: Colors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// DISTANCE CHIP
// ======================================================================

class _DistanceChip extends StatelessWidget {
  final String text;

  const _DistanceChip({
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return _Glass(
      radius: 20,
      borderColor: kBlue,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: kBlue,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
            Container(
              width: 14,
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: Colors.white24,
            ),
            const Icon(Icons.motorcycle_rounded, color: kAccent, size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.manrope(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================================
// MOTORCYCLE MARKER
// ======================================================================

class _MotorcycleMarker extends StatelessWidget {
  final bool live;

  const _MotorcycleMarker({
    required this.live,
  });

  @override
  Widget build(BuildContext context) {
    final color = live ? kAccent : Colors.grey;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        _Pulse(
          color: color,
          size: 96,
          active: live,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: live
                    ? const [Color(0xFFFFB347), Color(0xFFFF6B1A)]
                    : [Colors.grey.shade500, Colors.grey.shade700],
              ),
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.55),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(
              Icons.motorcycle_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
        ),
        if (!live)
          Positioned(
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'LAST KNOWN',
                maxLines: 1,
                style: GoogleFonts.manrope(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ======================================================================
// PHONE DOT  (blue "you are here" dot)
// ======================================================================

class _PhoneDot extends StatelessWidget {
  const _PhoneDot();

  @override
  Widget build(BuildContext context) {
    return _Pulse(
      color: kBlue,
      size: 52,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: kBlue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: kBlue.withValues(alpha: 0.55),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================================
// SEARCH MARKER
// ======================================================================

class _SearchMarker extends StatelessWidget {
  final String label;

  const _SearchMarker({
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxWidth: 150),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.manrope(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        const Icon(
          Icons.location_on_rounded,
          color: Colors.redAccent,
          size: 44,
          shadows: [
            Shadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
      ],
    );
  }
}

// ======================================================================
// GLASS PANEL
// ======================================================================

class _Glass extends StatelessWidget {
  final Widget child;
  final Color borderColor;
  final double radius;

  const _Glass({
    required this.child,
    this.borderColor = kAccent,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    final br = BorderRadius.circular(radius);

    return Container(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  kPanelHi.withValues(alpha: 0.90),
                  kPanel.withValues(alpha: 0.86),
                ],
              ),
              borderRadius: br,
              border: Border.all(color: borderColor.withValues(alpha: 0.35)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// COMPATIBILITY ALIAS
//
// Para gumana pa rin ang `TrackPage()` sa ibang file (dashboard.dart,
// notification_page.dart) nang hindi na kailangang palitan ang pangalan.
// ======================================================================

typedef TrackPage = MapPage;
