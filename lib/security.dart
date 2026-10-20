import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'my_device.dart';

/// MotoGuard Security Mode page.
///
/// Uses the currently registered device exposed by MotoDeviceRegistry.
/// Firebase path: /securityMode/<selected-device-id>
/// Values: 0 or WAITING = no level selected, 1 = Level 1, 2 = Level 2.
class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  static const Color _background = Color(0xFF0A0E17);
  static const Color _panel = Color(0xFF121826);
  static const Color _teal = Color(0xFF00E5C7);
  static const Color _amber = Color(0xFFFFB020);
  static const Color _red = Color(0xFFFF3B5C);
  static const Color _muted = Color(0xFF9AA4B5);

  final MotoDeviceRegistry _registry = MotoDeviceRegistry.instance;

  FirebaseDatabase? _database;
  DatabaseReference? _modeRef;
  StreamSubscription<DatabaseEvent>? _modeSubscription;

  String? _boundDeviceId;
  int _selectedLevel = 0;
  bool _saving = false;
  bool _registryRetained = false;
  String? _error;
  String? _rawValue;

  FirebaseDatabase get _db {
    return _database ??= FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: kMotoRtdbUrl,
    );
  }

  @override
  void initState() {
    super.initState();
    // SecurityPage may be opened without MyDevicePage remaining mounted.
    // Retain the shared registry so its authenticated device state is active.
    _registry.retain();
    _registryRetained = true;
    _registry.state.addListener(_onRegistryChanged);
    _bindDevice(_registry.state.value.device);
  }

  @override
  void dispose() {
    _registry.state.removeListener(_onRegistryChanged);
    _modeSubscription?.cancel();
    _modeSubscription = null;
    if (_registryRetained) {
      _registry.release();
    }
    super.dispose();
  }

  void _onRegistryChanged() {
    if (!mounted) return;
    final device = _registry.state.value.device;
    if (device?.id != _boundDeviceId) {
      _bindDevice(device);
    }
  }

  void _bindDevice(MotoDevice? device) {
    final nextId = device?.id;
    if (nextId == _boundDeviceId && _modeRef != null) return;

    _modeSubscription?.cancel();
    _modeSubscription = null;
    _modeRef = null;
    _boundDeviceId = nextId;
    _rawValue = null;
    _selectedLevel = 0;
    _error = null;

    if (nextId != null && nextId.trim().isNotEmpty) {
      final ref = _db.ref('securityMode/$nextId');
      _modeRef = ref;
      _modeSubscription = ref.onValue.listen(
        (event) {
          if (!mounted || _boundDeviceId != nextId) return;
          final raw = event.snapshot.value;
          setState(() {
            _rawValue = raw?.toString() ?? '(empty)';
            _selectedLevel = _parseLevel(raw);
          });
        },
        onError: (Object error) {
          if (!mounted || _boundDeviceId != nextId) return;
          setState(() {
            _error = 'Could not read this device mode from Firebase: $error';
          });
        },
      );
    }

    if (mounted) setState(() {});
  }

  int _parseLevel(Object? value) {
    if (value == null) return 0;
    final normalized = value.toString().trim().toUpperCase();
    if (normalized == 'LEVEL1' || normalized == '1') return 1;
    if (normalized == 'LEVEL2' || normalized == '2') return 2;
    return 0;
  }

  Future<void> _selectLevel(int level) async {
    if (level != 1 && level != 2) return;
    final ref = _modeRef;
    final deviceId = _boundDeviceId;

    if (ref == null || deviceId == null) {
      setState(() {
        _error = 'No registered MotoGuard device is connected to this account.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      debugPrint('MotoGuard: writing security level $level');
      debugPrint('MotoGuard device ID: $deviceId');
      debugPrint('MotoGuard Firebase path: ${ref.path}');

      await ref.set(level);
      final snapshot = await ref.get();
      final savedLevel = _parseLevel(snapshot.value);

      debugPrint('MotoGuard saved value: ${snapshot.value}');
      if (savedLevel != level) {
        throw StateError(
          'Firebase returned ${snapshot.value}, expected $level.',
        );
      }

      if (!mounted) return;
      setState(() {
        _selectedLevel = savedLevel;
        _rawValue = snapshot.value?.toString() ?? '(empty)';
        _saving = false;
      });
      _showMessage('Level $level saved for $deviceId.');
    } catch (e, stackTrace) {
      debugPrint('MotoGuard Firebase WRITE ERROR: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save Level $level: $e';
      });
      _showMessage('Could not save Level $level. Check the error below.');
    }
  }

  Future<void> _resetToWaiting() async {
    final ref = _modeRef;
    final deviceId = _boundDeviceId;
    if (ref == null || deviceId == null) {
      setState(() {
        _error = 'No registered MotoGuard device is connected to this account.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.set('WAITING');
      final snapshot = await ref.get();
      if (snapshot.value?.toString().trim().toUpperCase() != 'WAITING') {
        throw StateError(
            'Firebase did not save WAITING. Current: ${snapshot.value}');
      }

      if (!mounted) return;
      setState(() {
        _selectedLevel = 0;
        _rawValue = 'WAITING';
        _saving = false;
      });
      _showMessage('Waiting for level selection on $deviceId.');
    } catch (e, stackTrace) {
      debugPrint('MotoGuard reset error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not reset security mode: $e';
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final registryState = _registry.state.value;
    final device = registryState.device;

    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'SECURITY MODE',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2),
        ),
      ),
      body: SafeArea(
        child: registryState.loading
            ? const Center(child: CircularProgressIndicator(color: _teal))
            : registryState.error != null
                ? _centerMessage(registryState.error!, _red)
                : device == null
                    ? _centerMessage(
                        'No registered MotoGuard device found. Connect a device first in My Device.',
                        _muted,
                      )
                    : ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: _panel,
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                  color: _teal.withValues(alpha: 0.3)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.shield_moon_rounded,
                                    color: _teal, size: 36),
                                const SizedBox(height: 12),
                                const Text(
                                  'Choose your protection level',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Turn ON the physical ESP32 button, then choose a level here. The device should wait until you select a level.',
                                  style: TextStyle(color: _muted, height: 1.45),
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    const Icon(Icons.memory_rounded,
                                        color: _teal, size: 18),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        device.name,
                                        style: const TextStyle(
                                            color: _teal,
                                            fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text('Device ID: ${device.id}',
                                    style: const TextStyle(
                                        color: _muted, fontSize: 12)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _modeCard(
                            level: 1,
                            title: 'LEVEL 1',
                            subtitle: 'Basic movement detection',
                            details:
                                'Movement event sends an app notification.',
                            color: _amber,
                            icon: Icons.shield_rounded,
                            selected: _selectedLevel == 1,
                          ),
                          const SizedBox(height: 14),
                          _modeCard(
                            level: 2,
                            title: 'LEVEL 2',
                            subtitle: 'High-level protection',
                            details:
                                'Critical event can trigger the app alert/ringing flow.',
                            color: _red,
                            icon: Icons.shield_moon_rounded,
                            selected: _selectedLevel == 2,
                          ),
                          const SizedBox(height: 14),
                          OutlinedButton.icon(
                            onPressed: _saving ? null : _resetToWaiting,
                            icon: const Icon(Icons.hourglass_empty_rounded),
                            label: const Text('WAIT FOR LEVEL SELECTION'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _teal,
                              side: BorderSide(
                                  color: _teal.withValues(alpha: 0.6)),
                              padding: const EdgeInsets.symmetric(vertical: 15),
                            ),
                          ),
                          const SizedBox(height: 14),
                          _statusBox(
                            'Firebase path: /securityMode/${device.id}\nValue: ${_rawValue ?? 'Reading…'}\nMode: ${_levelLabel(_selectedLevel)}',
                            _selectedLevel == 2
                                ? _red
                                : _selectedLevel == 1
                                    ? _amber
                                    : _teal,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            _statusBox(_error!, _red),
                          ],
                          const SizedBox(height: 18),
                          const Text(
                            'If the value changes back to WAITING after selecting a level, check the ESP32 firmware. It should write WAITING only once when the physical button changes from OFF to ON, not repeatedly.',
                            style: TextStyle(
                                color: _muted, fontSize: 12, height: 1.45),
                          ),
                        ],
                      ),
      ),
    );
  }

  String _levelLabel(int level) {
    if (level == 1) return 'LEVEL 1';
    if (level == 2) return 'LEVEL 2';
    return 'WAITING FOR SELECTION';
  }

  Widget _centerMessage(String message, Color color) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: color, fontSize: 15, height: 1.5),
        ),
      ),
    );
  }

  Widget _modeCard({
    required int level,
    required String title,
    required String subtitle,
    required String details,
    required Color color,
    required IconData icon,
    required bool selected,
  }) {
    return Material(
      color: _panel,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: _saving ? null : () => _selectLevel(level),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: color.withValues(alpha: selected ? 0.85 : 0.3),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1)),
                    const SizedBox(height: 5),
                    Text(subtitle,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(details,
                        style: const TextStyle(color: _muted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_saving)
                const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: color,
                    size: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBox(String text, Color color) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: color, size: 19),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
