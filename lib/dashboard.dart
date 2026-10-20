import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'profile.dart';
import 'map.dart';
import 'add_motor.dart';
import 'motor_verification.dart';
import 'notification_page.dart';
import 'security.dart';

// =========================
// PHONE NUMBER FOR THE CALL BUTTON
// =========================
const String kCallNumber = '911';

// =========================
// MAX SIZES (scaled down automatically on small screens)
// =========================
const double kBikeWidth = 220;
const double kBikeHeight = 160;
const double kRadarSize = 260;
const double kMaxContentWidth = 620;

// =========================
// HEADER LOGO SIZE
// =========================
const double kLogoBoxSize = 42;
const double kLogoImageSize = 30;

// =========================
// FIRESTORE FIELDS
// =========================
const String kFieldBikePhoto = 'motorcyclePhotoB64';

// Photos are compressed first; a Firestore document is limited to 1 MiB.
const int kMaxPhotoBytes = 650000;

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int currentTab = 0;

  String motorcycleName = 'Loading...';

  bool isDarkMode = true;
  bool isRefreshing = false;

  // ---- Account-specific motorcycle photo (stored in Firestore) ----
  /// Photo bytes decoded from Firestore: users/{uid}.motorcyclePhotoB64
  Uint8List? bikePhotoBytes;
  String? _bikeB64;

  bool isUploadingPhoto = false;

  final ImagePicker _picker = ImagePicker();

  // Placeholder until your ESP32 sends battery data to Firebase.
  int batteryLevel = 92;

  final NotificationService _svc = NotificationService.instance;
  Timer? _statusTimer;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userSub;

  late final AnimationController _radarController;

  // Responsive values, recomputed in build().
  double _pad = 24;
  double _cardPad = 22;
  double _radar = kRadarSize;

  // =========================
  // DESIGN TOKENS
  // =========================

  Color get _bg =>
      isDarkMode ? const Color(0xFF080C14) : const Color(0xFFEEF2F7);

  Color get _bg2 =>
      isDarkMode ? const Color(0xFF0E1424) : const Color(0xFFE2E8F0);

  Color get _panelStart => isDarkMode
      ? const Color(0xFF131A2B).withValues(alpha: 0.95)
      : Colors.white.withValues(alpha: 0.97);

  Color get _panelEnd => isDarkMode
      ? const Color(0xFF181F33).withValues(alpha: 0.88)
      : const Color(0xFFF6F8FC);

  Color get _border =>
      isDarkMode ? const Color(0xFF28324A) : const Color(0xFFD5DCE6);

  Color get _signal =>
      isDarkMode ? const Color(0xFF00E5C7) : const Color(0xFF00A88F);

  Color get _amber =>
      isDarkMode ? const Color(0xFFFFB020) : const Color(0xFFC97A00);

  Color get _crimson =>
      isDarkMode ? const Color(0xFFFF3B5C) : const Color(0xFFD8214A);

  Color get _text =>
      isDarkMode ? const Color(0xFFF4F6F9) : const Color(0xFF11151E);

  Color get _mist =>
      isDarkMode ? const Color(0xFF8A93A6) : const Color(0xFF5B6472);

  Color get _shadowColor => isDarkMode
      ? Colors.black.withValues(alpha: 0.35)
      : const Color(0xFF1B2A41).withValues(alpha: 0.09);

  // =========================
  // DEVICE + GPS STATUS (single source of truth)
  // =========================

  OwnedDevice? get _primaryDevice =>
      _svc.devices.value.isEmpty ? null : _svc.devices.value.first;

  bool get _deviceOnline {
    final device = _primaryDevice;
    return device != null && _svc.isOnline(device.id);
  }

  /// GPS label used by BOTH the telemetry strip and the My Device pill.
  String get _gpsLabel {
    final device = _primaryDevice;

    if (device == null) return 'NO DEVICE';
    if (!_deviceOnline) return 'NO SIGNAL';

    // Online alone does not confirm a valid GPS fix.
    return 'NO DATA';
  }

  Color get _gpsColor {
    switch (_gpsLabel) {
      case 'STRONG':
        return _signal;
      case 'NO SIGNAL':
        return _crimson;
      case 'NO DEVICE':
        return _mist;
      default:
        return _amber;
    }
  }

  String get _lastPingLabel {
    final device = _primaryDevice;
    if (device == null) return '--';

    final seen = _svc.lastSeen(device.id);
    if (seen == null) return '--';

    final difference = DateTime.now().difference(seen);

    if (difference.isNegative) return 'JUST NOW';
    if (difference.inSeconds < 5) return 'JUST NOW';
    if (difference.inMinutes < 1) return '${difference.inSeconds}S AGO';
    if (difference.inHours < 1) return '${difference.inMinutes}M AGO';
    if (difference.inDays < 1) return '${difference.inHours}H AGO';

    return '${difference.inDays}D AGO';
  }

  // =========================
  // INIT
  // =========================

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );

    if (!WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations) {
      _radarController.repeat();
    }

    _svc.start();

    _statusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (mounted) setState(() {});
      },
    );

    // Re-subscribe whenever the signed-in account changes so the correct
    // photo/name always shows for that account on any device.
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      _listenToUserDoc(user);
    });

    _initializeApp();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initializeApp();
      _svc.start();
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _authSub?.cancel();
    _userSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _radarController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    await loadTheme();
    if (!mounted) return;
    await _loadUserProfile();
  }

  Future<void> openSecurityPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SecurityPage()),
    );
  }

  // =========================
  // REFRESH
  // =========================

  Future<void> _fetchLatestData() async {
    if (!mounted) return;

    setState(() => isRefreshing = true);

    try {
      await _loadUserProfile();
      await _svc.start();
    } finally {
      if (mounted) {
        setState(() => isRefreshing = false);
      }
    }
  }

  // =========================
  // THEME
  // =========================

  Future<void> loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() {
      isDarkMode = prefs.getBool('isDarkMode') ?? true;
    });

    _updateSystemUI();
  }

  void _updateSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            isDarkMode ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: _bg,
        systemNavigationBarIconBrightness:
            isDarkMode ? Brightness.light : Brightness.dark,
      ),
    );
  }

  // =========================
  // USER PROFILE (name + photo, synced from Firestore)
  // =========================

  void _applyUserData(Map<String, dynamic>? data) {
    if (!mounted) return;

    final raw = data?[kFieldBikePhoto]?.toString();
    final b64 = (raw == null || raw.isEmpty) ? null : raw;

    Uint8List? bytes = bikePhotoBytes;
    String? currentB64 = _bikeB64;

    if (!isUploadingPhoto && b64 != _bikeB64) {
      currentB64 = b64;
      try {
        bytes = b64 == null ? null : base64Decode(b64);
      } catch (_) {
        bytes = null;
      }
    }

    setState(() {
      motorcycleName = data?['motorcycleName']?.toString() ?? 'Honda XRM 125';
      _bikeB64 = currentB64;
      bikePhotoBytes = bytes;
    });
  }

  /// Live listener: a photo changed on one phone appears on every other
  /// device signed in to the same account.
  void _listenToUserDoc(User? user) {
    _userSub?.cancel();
    _userSub = null;

    if (user == null) {
      if (!mounted) return;
      setState(() {
        motorcycleName = 'Honda XRM 125';
        bikePhotoBytes = null;
        _bikeB64 = null;
      });
      return;
    }

    _userSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen(
          (snap) => _applyUserData(snap.data()),
          onError: (_) {},
        );
  }

  Future<void> _loadUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _applyUserData(null);
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      _applyUserData(doc.data());
    } catch (_) {
      if (!mounted) return;
      if (motorcycleName == 'Loading...') {
        setState(() => motorcycleName = 'Honda XRM 125');
      }
    }
  }

  Future<void> saveMotorcycleName(String newName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      snack('Please sign in first.');
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {'motorcycleName': newName},
        SetOptions(merge: true),
      );

      if (!mounted) return;
      setState(() => motorcycleName = newName);
    } catch (_) {
      if (!mounted) return;
      snack('Unable to save motorcycle name.');
    }
  }

  // =========================
  // MOTORCYCLE PHOTO (saved to the user's Firestore document)
  // =========================

  Future<void> _pickBikePhoto(ImageSource source) async {
    if (isUploadingPhoto) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      snack('Please sign in to save your motorcycle photo.');
      return;
    }

    try {
      // Small + compressed so it fits inside a Firestore document.
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 700,
        maxHeight: 700,
        imageQuality: 70,
      );

      if (picked == null) return;

      final bytes = await picked.readAsBytes();

      if (bytes.length > kMaxPhotoBytes) {
        snack('Photo is too large. Please choose a smaller one.');
        return;
      }

      if (!mounted) return;

      final b64 = base64Encode(bytes);

      setState(() {
        isUploadingPhoto = true;
        bikePhotoBytes = bytes; // instant preview
        _bikeB64 = b64;
      });

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {
          kFieldBikePhoto: b64,
          'motorcyclePhotoUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      if (!mounted) return;

      setState(() => isUploadingPhoto = false);
      snack('Motorcycle photo updated');
    } on PlatformException {
      await _uploadFailed(
          'Cannot access the camera or gallery. Check app permissions.');
    } on FirebaseException {
      await _uploadFailed(
          'Upload failed. Check your connection and try again.');
    } catch (_) {
      await _uploadFailed('Unable to update the motorcycle photo.');
    }
  }

  Future<void> _uploadFailed(String message) async {
    if (!mounted) return;
    setState(() => isUploadingPhoto = false);
    snack(message);
    // Restore whatever is actually saved on the account.
    await _loadUserProfile();
  }

  Future<void> _removeBikePhoto() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      snack('Please sign in first.');
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {kFieldBikePhoto: FieldValue.delete()},
        SetOptions(merge: true),
      );

      if (!mounted) return;

      setState(() {
        bikePhotoBytes = null;
        _bikeB64 = null;
      });
      snack('Default motorcycle image restored');
    } catch (_) {
      snack('Unable to remove the photo.');
    }
  }

  bool get _hasCustomPhoto => bikePhotoBytes != null;

  // =========================
  // EDIT SHEET
  // =========================

  Future<void> _openEditSheet() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        final maxH = MediaQuery.of(sheetContext).size.height * 0.9;

        return SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 560, maxHeight: maxH),
              child: Container(
                margin: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDarkMode ? const Color(0xFF121826) : Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: _border, width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: _shadowColor,
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: _mist.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'EDIT MOTORCYCLE',
                        style: _mono(
                          size: 11.5,
                          weight: FontWeight.w800,
                          color: _signal,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _sheetOption(
                        icon: Icons.edit_rounded,
                        title: 'Edit name',
                        subtitle: 'Change your motorcycle name',
                        color: _amber,
                        onTap: () => Navigator.pop(sheetContext, 'name'),
                      ),
                      const SizedBox(height: 10),
                      _sheetOption(
                        icon: Icons.photo_library_rounded,
                        title: 'Choose from gallery',
                        subtitle: 'Saved to your account on every device',
                        color: _signal,
                        onTap: () => Navigator.pop(sheetContext, 'gallery'),
                      ),
                      const SizedBox(height: 10),
                      _sheetOption(
                        icon: Icons.photo_camera_rounded,
                        title: 'Take a photo',
                        subtitle: 'Capture your motorcycle now',
                        color: _signal,
                        onTap: () => Navigator.pop(sheetContext, 'camera'),
                      ),
                      if (_hasCustomPhoto) ...[
                        const SizedBox(height: 10),
                        _sheetOption(
                          icon: Icons.restart_alt_rounded,
                          title: 'Use default image',
                          subtitle: 'Remove your custom photo',
                          color: _crimson,
                          onTap: () => Navigator.pop(sheetContext, 'reset'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;

    switch (action) {
      case 'name':
        await openEditPage();
        break;
      case 'gallery':
        await _pickBikePhoto(ImageSource.gallery);
        break;
      case 'camera':
        await _pickBikePhoto(ImageSource.camera);
        break;
      case 'reset':
        await _removeBikePhoto();
        break;
    }
  }

  Widget _sheetOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              color.withValues(alpha: 0.12),
              color.withValues(alpha: 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.manrope(
                      color: _text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: GoogleFonts.manrope(
                      color: _mist,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, color: _mist, size: 14),
          ],
        ),
      ),
    );
  }

  // =========================
  // NAVIGATION
  // =========================

  Future<void> nav(int index) async {
    if (!mounted) return;

    setState(() => currentTab = index);

    if (index == 0) return;

    if (index == 1) {
      await Navigator.push(
        context,
        // TODO: palitan ang `MapPage` ng TUNAY na pangalan ng class sa
        // map.dart (walang `const`). Hanapin ang `extends StatefulWidget`.
        MaterialPageRoute(builder: (_) => MapPage()),
      );

      if (!mounted) return;
      setState(() => currentTab = 0);
    } else if (index == 2) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ProfilePage()),
      );

      if (!mounted) return;
      await loadTheme();

      if (!mounted) return;
      setState(() => currentTab = 0);
    }
  }

  Future<void> openNotifications() async {
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NotificationPage(isDarkMode: isDarkMode),
      ),
    );

    if (!mounted) return;
    await loadTheme();
  }

  Future<void> openEditPage() async {
    if (!mounted) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddMotorPage(currentName: motorcycleName),
      ),
    );

    if (!mounted) return;

    if (result != null) {
      await saveMotorcycleName(result.toString());
    }
  }

  void _openMyDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MotorVerificationPage()),
    );
  }

  // =========================
  // PHONE CALL
  // =========================

  Future<void> _callPhone() async {
    final uri = Uri(scheme: 'tel', path: kCallNumber);

    try {
      final launched = await launchUrl(uri);
      if (!launched) {
        snack('Unable to open the phone dialer.');
      }
    } catch (_) {
      snack('Unable to open the phone dialer.');
    }
  }

  // =========================
  // SNACKBAR
  // =========================

  void snack(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        elevation: 8,
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDarkMode ? const Color(0xFF171E30) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        content: Text(
          message,
          style: GoogleFonts.manrope(
            color: _text,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // =========================
  // TEXT STYLES
  // =========================

  TextStyle _display({
    required double size,
    FontWeight weight = FontWeight.w700,
    Color? color,
    double? letterSpacing,
  }) {
    return GoogleFonts.rajdhani(
      fontSize: size,
      fontWeight: weight,
      color: color ?? _text,
      letterSpacing: letterSpacing,
      height: 1,
    );
  }

  TextStyle _mono({
    required double size,
    FontWeight weight = FontWeight.w600,
    Color? color,
    double letterSpacing = 1,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: weight,
      color: color ?? _mist,
      letterSpacing: letterSpacing,
    );
  }

  // =========================
  // LAYOUT HELPERS
  // =========================

  /// Centers content and caps its width on tablets / landscape.
  Widget _constrain(Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
        child: child,
      ),
    );
  }

  BoxDecoration _cardDecoration({double radius = 28}) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_panelStart, _panelEnd],
      ),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: _border, width: 1.1),
      boxShadow: [
        BoxShadow(
          color: _shadowColor,
          blurRadius: 28,
          offset: const Offset(0, 14),
        ),
      ],
    );
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    // Keep layout stable even with very large system font settings.
    final clampedScaler = MediaQuery.textScalerOf(context).clamp(
      minScaleFactor: 0.9,
      maxScaleFactor: 1.25,
    );

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: clampedScaler),
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            _buildStaticBackground(),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final contentWidth =
                      width < kMaxContentWidth ? width : kMaxContentWidth;

                  _pad =
                      contentWidth < 360 ? 14 : (contentWidth < 420 ? 18 : 24);
                  _cardPad = contentWidth < 360 ? 16 : 22;

                  final available = contentWidth - (_pad * 2) - (_cardPad * 2);
                  _radar = available.clamp(190.0, kRadarSize).toDouble();

                  return Column(
                    children: [
                      Expanded(
                        child: RefreshIndicator(
                          color: _signal,
                          backgroundColor: _panelStart,
                          onRefresh: _fetchLatestData,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics(),
                            ),
                            padding: const EdgeInsets.only(bottom: 16),
                            children: [
                              const SizedBox(height: 14),
                              _constrain(_header()),
                              _constrain(_guardConsoleCard()),
                              _constrain(_quickActions()),
                            ],
                          ),
                        ),
                      ),
                      _constrain(_bottomNav()),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStaticBackground() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_bg, _bg2],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            right: -70,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    _signal.withValues(alpha: isDarkMode ? 0.16 : 0.10),
                    _signal.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -140,
            left: -80,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    _amber.withValues(alpha: isDarkMode ? 0.11 : 0.07),
                    _amber.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================
  // HEADER
  // =========================

  Widget _headerLogo() {
    return Container(
      width: kLogoBoxSize,
      height: kLogoBoxSize,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _signal.withValues(alpha: 0.24),
            _signal.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: _signal.withValues(alpha: 0.38)),
        boxShadow: [
          BoxShadow(
            color: _signal.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Image.asset(
        'assets/quad_bike.png',
        width: kLogoImageSize,
        height: kLogoImageSize,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Icon(Icons.shield_moon_rounded, color: _signal, size: 20);
        },
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _pad),
      child: Row(
        children: [
          _headerLogo(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: 'MOTO',
                        style: _display(size: 20, letterSpacing: 1.6),
                      ),
                      TextSpan(
                        text: 'GUARD',
                        style: _display(
                          size: 20,
                          color: _signal,
                          letterSpacing: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'RIDER DASHBOARD',
                  style: _mono(size: 9, letterSpacing: 1.6),
                ),
              ],
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: isRefreshing
                ? SizedBox(
                    key: const ValueKey('refreshing'),
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: _signal,
                    ),
                  )
                : const SizedBox(key: ValueKey('idle'), width: 18, height: 18),
          ),
        ],
      ),
    );
  }

  // =========================
  // GUARD CONSOLE
  // =========================

  Widget _guardConsoleCard() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: _pad, vertical: 18),
      padding: EdgeInsets.all(_cardPad),
      decoration: _cardDecoration(radius: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _signal.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _signal.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: _signal,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _signal.withValues(alpha: 0.7),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          'ACTIVE GUARD',
                          overflow: TextOverflow.ellipsis,
                          style: _mono(
                            size: 11,
                            weight: FontWeight.w700,
                            color: _signal,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _openEditSheet,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _amber.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: _amber.withValues(alpha: 0.28)),
                  ),
                  child: Icon(Icons.edit_rounded, color: _amber, size: 19),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            'YOUR MOTORCYCLE',
            style: _mono(size: 11.5, letterSpacing: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            motorcycleName,
            style: _display(size: 31, letterSpacing: -0.3),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 18),
          Center(child: _radarBike()),
          const SizedBox(height: 20),
          _telemetryStrip(),
        ],
      ),
    );
  }

  // =========================
  // BIKE IMAGE
  // =========================

  Widget _bikeFallbackIcon() {
    return Center(
      child: Container(
        height: 96,
        width: 96,
        decoration: BoxDecoration(
          color: _signal.withValues(alpha: 0.12),
          shape: BoxShape.circle,
          border: Border.all(color: _signal.withValues(alpha: 0.30)),
        ),
        child: Icon(Icons.motorcycle_rounded, size: 46, color: _signal),
      ),
    );
  }

  Widget _defaultBikeImage(double w, double h) {
    return Image.asset(
      'assets/bike.png',
      width: w,
      height: h,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => _bikeFallbackIcon(),
    );
  }

  Widget _bikeImage() {
    final w = _radar * (kBikeWidth / kRadarSize);
    final h = _radar * (kBikeHeight / kRadarSize);

    final bytes = bikePhotoBytes;

    final Widget image = bytes == null
        ? _defaultBikeImage(w, h)
        : Image.memory(
            bytes,
            key: ValueKey(_bikeB64.hashCode),
            width: w,
            height: h,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) =>
                _defaultBikeImage(w, h),
          );

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: image),
          if (isUploadingPhoto)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: _signal,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _radarBike() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _radar,
          width: _radar,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // soft glow behind the bike
              Container(
                width: _radar * 0.82,
                height: _radar * 0.82,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _signal.withValues(alpha: isDarkMode ? 0.14 : 0.10),
                      _signal.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _radarController,
                builder: (context, _) {
                  return CustomPaint(
                    size: Size(_radar, _radar),
                    painter: _RadarPainter(
                      progress: _radarController.value,
                      color: _signal,
                    ),
                  );
                },
              ),
              _bikeImage(),
              Positioned(
                right: 6,
                bottom: 10,
                child: GestureDetector(
                  onTap: _openEditSheet,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _panelStart,
                      shape: BoxShape.circle,
                      border: Border.all(color: _signal.withValues(alpha: 0.4)),
                      boxShadow: [
                        BoxShadow(
                          color: _shadowColor,
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.photo_camera_rounded,
                      color: _signal,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _signal.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _signal.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _signal,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                'LIVE VIEW',
                style: _mono(
                  size: 10.5,
                  weight: FontWeight.w700,
                  color: _signal,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =========================
  // TELEMETRY STRIP
  // =========================

  Widget _telemetryStrip() {
    return AnimatedBuilder(
      animation: _svc.changes,
      builder: (context, _) {
        return Row(
          children: [
            Expanded(
              child: _telemetryTile(
                Icons.gps_fixed_rounded,
                'GPS',
                _gpsLabel,
                _gpsColor,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _telemetryTile(
                Icons.battery_charging_full_rounded,
                'BATTERY',
                '$batteryLevel%',
                _amber,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _telemetryTile(
                Icons.schedule_rounded,
                'LAST PING',
                _lastPingLabel,
                _mist,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _telemetryTile(
    IconData icon,
    String label,
    String value,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDarkMode ? 0.08 : 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    style: _mono(size: 9, color: _mist, letterSpacing: 0.6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: _mono(
                size: 12.5,
                weight: FontWeight.w800,
                color: color,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================
  // QUICK ACTIONS
  // =========================

  Widget _quickActions() {
    return Padding(
      padding: EdgeInsets.fromLTRB(_pad, 0, _pad, 12),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _svc.changes,
            builder: (context, _) {
              return Row(
                children: [
                  Expanded(
                    child: _actionCard(
                      Icons.explore_rounded,
                      'LIVE\nTRACK',
                      _signal,
                      () => nav(1),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _actionCard(
                      Icons.shield_moon_rounded,
                      'SECURITY\nMODE',
                      _signal,
                      openSecurityPage,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _actionCard(
                      Icons.phone_rounded,
                      'CALL\nPHONE',
                      _crimson,
                      _callPhone,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _openMyDevice,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_signal.withValues(alpha: 0.18), _panelStart],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _signal.withValues(alpha: 0.38)),
                boxShadow: [
                  BoxShadow(
                    color: _signal.withValues(alpha: 0.10),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: _signal.withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: _signal.withValues(alpha: 0.32)),
                    ),
                    child: Icon(Icons.memory_rounded, color: _signal, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MY DEVICE',
                          style: _mono(
                            size: 11,
                            weight: FontWeight.w800,
                            color: _signal,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Manage your MotoGuard connection',
                          style:
                              _mono(size: 10, color: _mist, letterSpacing: 0),
                        ),
                        const SizedBox(height: 8),
                        _deviceStatusPill(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.arrow_forward_ios_rounded,
                      color: _signal, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _recentMessages(),
        ],
      ),
    );
  }

  /// Shows the SAME GPS status as the telemetry strip (no "Offline" state).
  Widget _deviceStatusPill() {
    return AnimatedBuilder(
      animation: _svc.changes,
      builder: (context, _) {
        final color = _gpsColor;
        final label = 'GPS · $_gpsLabel';

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: _mono(
                    size: 9,
                    weight: FontWeight.w800,
                    color: color,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // =========================
  // RECENT ACTIVITY
  // =========================

  Widget _recentMessages() {
    final palette = MgPalette(isDarkMode);

    return AnimatedBuilder(
      animation: _svc.changes,
      builder: (context, _) {
        final recent = _svc.visible.take(2).toList();

        Widget body;

        if (_svc.error.value != null && _svc.devices.value.isEmpty) {
          body = _messageInfoCard(
            Icons.error_outline_rounded,
            _crimson,
            _svc.error.value!,
          );
        } else if (!_svc.loaded.value) {
          body = Padding(
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: _signal,
                ),
              ),
            ),
          );
        } else if (_svc.devices.value.isEmpty) {
          body = _messageInfoCard(
            Icons.memory_rounded,
            _amber,
            'No registered MotoGuard device found. Register your device to receive security alerts.',
          );
        } else if (recent.isEmpty) {
          body = _messageInfoCard(
            Icons.notifications_none_rounded,
            _mist,
            'No alerts yet. Notifications from your registered devices will appear here.',
          );
        } else {
          body = Column(
            children: [
              for (final notification in recent)
                NotificationTile(
                  n: notification,
                  p: palette,
                  compact: true,
                  onTap: () async {
                    await _svc.markRead(notification.id);
                    if (!mounted) return;
                    await openNotifications();
                  },
                ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 3,
                      height: 14,
                      decoration: BoxDecoration(
                        color: _signal,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'RECENT ACTIVITY',
                      style: _mono(
                        size: 11,
                        weight: FontWeight.w800,
                        color: _mist,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ],
                ),
                GestureDetector(
                  onTap: openNotifications,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'VIEW ALL',
                      style: _mono(
                        size: 10,
                        weight: FontWeight.w800,
                        color: _signal,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            body,
          ],
        );
      },
    );
  }

  Widget _messageInfoCard(IconData icon, Color color, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(radius: 20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.manrope(
                fontSize: 12,
                height: 1.4,
                color: _mist,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================
  // ACTION CARD
  // =========================

  Widget _actionCard(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap, {
    int badge = 0,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          constraints: const BoxConstraints(minHeight: 128),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color.withValues(alpha: 0.10), _panelStart],
            ),
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: _shadowColor,
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(height: 3, color: color),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Icon(icon, size: 25, color: color),
                        ),
                        if (badge > 0)
                          Positioned(
                            top: -4,
                            right: -6,
                            child: Container(
                              constraints: const BoxConstraints(
                                minWidth: 18,
                                minHeight: 18,
                              ),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: _crimson,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: _panelStart,
                                  width: 1.5,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                badge > 99 ? '99+' : '$badge',
                                style: _mono(
                                  size: 9,
                                  color: Colors.white,
                                  weight: FontWeight.w800,
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: _mono(
                          size: 10,
                          weight: FontWeight.w700,
                          color: _text,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================
  // BOTTOM NAV
  // =========================

  Widget _bottomNav() {
    return Container(
      height: 70,
      margin: EdgeInsets.fromLTRB(_pad, 6, _pad, 12),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: _panelStart,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: _border, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: _shadowColor,
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          _navItem(Icons.grid_view_rounded, 'HOME', 0),
          _navItem(Icons.map_rounded, 'MAP', 1),
          _navItem(Icons.person_rounded, 'PROFILE', 2),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index) {
    final active = currentTab == index;

    return Expanded(
      child: GestureDetector(
        onTap: () => nav(index),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color:
                active ? _signal.withValues(alpha: 0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color:
                  active ? _signal.withValues(alpha: 0.30) : Colors.transparent,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: active ? _signal : _mist, size: 22),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: _mono(
                    size: 9,
                    weight: FontWeight.w700,
                    color: active ? _signal : _mist,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =========================
// RADAR PAINTER
// =========================

class _RadarPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _RadarPainter({
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;

    // faint static guide rings
    final guide = Paint()
      ..color = color.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawCircle(center, maxRadius * 0.99, guide);
    canvas.drawCircle(center, maxRadius * 0.66, guide);
    canvas.drawCircle(center, maxRadius * 0.33, guide);

    // animated pulse rings
    for (int i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final radius = maxRadius * t;
      final opacity = (1 - t).clamp(0.0, 1.0) * 0.55;

      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
