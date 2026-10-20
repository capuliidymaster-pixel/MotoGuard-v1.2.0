import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;

  bool isDarkMode = true;

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

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      isDarkMode = prefs.getBool("isDarkMode") ?? true;
    });
  }

  // ================= CHANGE PASSWORD =================
  Future<void> _changePassword() async {
    final current = _currentController.text.trim();
    final newPass = _newController.text.trim();
    final confirm = _confirmController.text.trim();

    if (current.isEmpty || newPass.isEmpty || confirm.isEmpty) {
      _showToast("Please fill all fields");
      return;
    }

    if (newPass.length < 6) {
      _showToast("New password must be at least 6 characters");
      return;
    }

    if (newPass != confirm) {
      _showToast("New passwords do not match");
      return;
    }

    if (newPass == current) {
      _showToast("New password must be different from current");
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) {
      _showToast("No user is logged in");
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Re-authenticate first (Firebase requires a recent login)
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: current,
      );
      await user.reauthenticateWithCredential(credential);

      // Update to the new password
      await user.updatePassword(newPass);

      if (!mounted) return;

      _showToast("Password updated successfully");
      Navigator.pop(context, true);
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'wrong-password':
        case 'invalid-credential':
          _showToast("Current password is incorrect");
          break;
        case 'weak-password':
          _showToast("New password is too weak");
          break;
        case 'requires-recent-login':
          _showToast("Please log in again, then retry");
          break;
        case 'too-many-requests':
          _showToast("Too many attempts. Try again later");
          break;
        default:
          _showToast(e.message ?? "Failed to update password");
      }
    } catch (e) {
      _showToast("Something went wrong");
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ================= FORGOT PASSWORD =================
  Future<void> _sendResetEmail() async {
    final email = FirebaseAuth.instance.currentUser?.email;
    if (email == null) {
      _showToast("No email found for this account");
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      _showToast("Reset link sent to $email");
    } on FirebaseAuthException catch (e) {
      _showToast(e.message ?? "Failed to send reset email");
    }
  }

  // ================= SNACKBAR =================
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: _text),
        title: Text(
          "Change Password",
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
                        Icons.lock_reset_rounded,
                        color: _accent,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 15),
                    Text(
                      "Secure Your Account",
                      style: TextStyle(
                        color: _text,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Enter your current password, then choose a new one.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _subtext, fontSize: 13),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 25),

              // ================= FORM =================
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
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
                child: Column(
                  children: [
                    _buildField(
                      controller: _currentController,
                      label: "Current Password",
                      icon: Icons.lock_outline,
                      obscure: _obscureCurrent,
                      onToggle: () =>
                          setState(() => _obscureCurrent = !_obscureCurrent),
                    ),
                    const SizedBox(height: 16),
                    _buildField(
                      controller: _newController,
                      label: "New Password",
                      icon: Icons.lock_open_rounded,
                      obscure: _obscureNew,
                      onToggle: () =>
                          setState(() => _obscureNew = !_obscureNew),
                    ),
                    const SizedBox(height: 16),
                    _buildField(
                      controller: _confirmController,
                      label: "Confirm New Password",
                      icon: Icons.lock_reset_outlined,
                      obscure: _obscureConfirm,
                      onToggle: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _sendResetEmail,
                        child: Text(
                          "Forgot current password?",
                          style: TextStyle(
                            color: _accent,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 30),

              // ================= SAVE BUTTON =================
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    shadowColor: _accent.withValues(alpha: 0.5),
                    elevation: 8,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: _isLoading ? null : _changePassword,
                  child: _isLoading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          "Update Password",
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ================= PASSWORD FIELD =================
  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: _subtext,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: TextStyle(color: _text, fontSize: 15),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: _accent, size: 20),
            suffixIcon: IconButton(
              icon: Icon(
                obscure ? Icons.visibility_off : Icons.visibility,
                color: _subtext,
                size: 18,
              ),
              onPressed: onToggle,
            ),
            filled: true,
            fillColor: _fieldBg,
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
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
    );
  }
}
