import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpCenterPage extends StatefulWidget {
  const HelpCenterPage({super.key});

  @override
  State<HelpCenterPage> createState() => _HelpCenterPageState();
}

class _HelpCenterPageState extends State<HelpCenterPage> {
  bool isDarkMode = true;
  String _query = "";

  // TODO: change to your real support email
  static const String _supportEmail = "motoguard@gmail.com";

  // ================= DESIGN SYSTEM COLORS =================
  final Color _accent = const Color(0xFFFF1E1E);

  Color get _bg =>
      isDarkMode ? const Color(0xFF060B14) : const Color(0xFFF4F4F4);
  Color get _card =>
      isDarkMode ? const Color(0xFF0D131D) : const Color(0xFFFFFFFF);
  Color get _text =>
      isDarkMode ? const Color(0xFFFFFFFF) : const Color(0xFF111111);
  Color get _subtext =>
      isDarkMode ? const Color(0xFF9CA3AF) : const Color(0xFF666666);
  Color get _fieldBg =>
      isDarkMode ? const Color(0xFF1A2332) : const Color(0xFFF0F0F0);
  Color get _borderColor => isDarkMode
      ? Colors.white.withValues(alpha: 0.05)
      : const Color(0xFFECECEC);
  Color get _shadowColor =>
      isDarkMode ? Colors.black38 : Colors.black.withValues(alpha: 0.04);

  // ================= FAQ DATA =================
  final List<Map<String, String>> _faqs = const [
    {
      "q": "How do I track my motorcycle in real time?",
      "a":
          "Open the map screen after logging in. As long as your MotoGuard device is powered on and connected, your motorcycle's live GPS position is shown on the map and updates automatically.",
    },
    {
      "q": "The map is not showing my location.",
      "a":
          "Make sure Location permission is set to \"Allow\" for MotoGuard in your phone settings, GPS is turned on, and you have a stable internet connection. Then restart the app.",
    },
    {
      "q": "My device is not connecting.",
      "a":
          "Check that the tracker has power and a good GPS signal (outdoors works best). If you connect through USB, use a data-capable cable and approve the USB permission prompt on your phone.",
    },
    {
      "q": "I'm not receiving notifications or alerts.",
      "a":
          "Enable notifications for MotoGuard in your phone settings and turn off battery optimization for the app so alerts can arrive while it runs in the background.",
    },
    {
      "q": "How do I change my password?",
      "a":
          "Go to Profile > Account Settings > Change Password. You'll need to enter your current password first. If you forgot it, tap \"Forgot current password?\" to get a reset link by email.",
    },
    {
      "q": "How do I change my name or profile picture?",
      "a":
          "Open your Profile. Tap the camera icon on your avatar to change your photo, or the pencil icon at the top right to edit your name and email.",
    },
    {
      "q": "Can I use the app on more than one account?",
      "a":
          "Yes. Each account has its own profile data. Just log out from the Profile page and log in with another account.",
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      isDarkMode = prefs.getBool("isDarkMode") ?? true;
    });
  }

  // ================= CONTACT SUPPORT =================
  Future<void> _contactSupport() async {
    final uri = Uri(
      scheme: 'mailto',
      path: _supportEmail,
      query: _encodeQuery({
        'subject': 'MotoGuard Support Request',
        'body': 'Describe your issue here:\n\n',
      }),
    );

    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        _showToast("No email app found. Contact us at $_supportEmail");
      }
    } catch (e) {
      _showToast("Could not open email app");
    }
  }

  String _encodeQuery(Map<String, String> params) {
    return params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: _card,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  List<Map<String, String>> get _filteredFaqs {
    if (_query.trim().isEmpty) return _faqs;
    final q = _query.toLowerCase();
    return _faqs
        .where((f) =>
            f["q"]!.toLowerCase().contains(q) ||
            f["a"]!.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final faqs = _filteredFaqs;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: _text),
        title: Text(
          "Help Center",
          style: TextStyle(
            color: _text,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Column(
            children: [
              // ================= HEADER =================
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(25),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: _borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: _shadowColor,
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      height: 70,
                      width: 70,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _accent.withValues(alpha: 0.12),
                        border: Border.all(color: _accent, width: 2),
                      ),
                      child: Icon(
                        Icons.support_agent_rounded,
                        color: _accent,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 15),
                    Text(
                      "How can we help?",
                      style: TextStyle(
                        color: _text,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Browse common questions or contact our team.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _subtext, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      onChanged: (v) => setState(() => _query = v),
                      style: TextStyle(color: _text, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: "Search help topics",
                        hintStyle: TextStyle(color: _subtext, fontSize: 14),
                        prefixIcon:
                            Icon(Icons.search, color: _accent, size: 20),
                        filled: true,
                        fillColor: _fieldBg,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 14),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _accent, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 30),

              // ================= FAQ SECTION =================
              _sectionTitle("Frequently Asked Questions"),

              if (faqs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    "No results found. Try different keywords or contact support below.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _subtext, fontSize: 13),
                  ),
                )
              else
                ...faqs.map(_faqTile),

              const SizedBox(height: 20),

              // ================= CONTACT SECTION =================
              _sectionTitle("Still Need Help?"),

              Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: _shadowColor,
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ListTile(
                  onTap: _contactSupport,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  leading: Icon(Icons.email_outlined, color: _accent),
                  title: Text(
                    "Email Support",
                    style: TextStyle(
                      color: _text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    _supportEmail,
                    style: TextStyle(color: _subtext, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: _subtext),
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ================= SECTION TITLE =================
  Widget _sectionTitle(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 5),
        child: Text(
          text,
          style: TextStyle(
            color: _subtext,
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
      ),
    );
  }

  // ================= FAQ TILE =================
  Widget _faqTile(Map<String, String> faq) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _borderColor),
        boxShadow: [
          BoxShadow(
            color: _shadowColor,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            iconColor: _accent,
            collapsedIconColor: _subtext,
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
            childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            leading: Icon(Icons.help_outline, color: _accent),
            title: Text(
              faq["q"]!,
              style: TextStyle(
                color: _text,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            children: [
              Text(
                faq["a"]!,
                style: TextStyle(
                  color: _subtext,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
