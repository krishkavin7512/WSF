import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/sentra_design.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();

  bool _isOtpSent = false;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// E.164: if input starts with `+`, keep country code + digits; else default +91.
  String? _formatPhoneE164(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('+')) {
      final rest = trimmed.substring(1).replaceAll(RegExp(r'\D'), '');
      if (rest.length < 8) return null;
      return '+$rest';
    }

    var digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    if (digits.length == 11 && digits.startsWith('91')) {
      return '+$digits';
    }
    if (digits.length == 10) {
      return '+91$digits';
    }
    if (digits.length >= 10) {
      return '+91${digits.substring(digits.length - 10)}';
    }
    return null;
  }

  Future<void> _sendOtp() async {
    if (!_formKey.currentState!.validate()) return;

    final formatted = _formatPhoneE164(_phoneController.text);
    if (formatted == null) {
      _showError('Enter a valid phone number.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await Supabase.instance.client.auth.signInWithOtp(
        phone: formatted,
        data: {'full_name': _nameController.text.trim()},
      );
      if (!mounted) return;
      setState(() {
        _isOtpSent = true;
        _isSubmitting = false;
      });
    } on AuthException catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError(e.message);
    } catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError('Could not send OTP. Try again.');
    }
  }

  Future<void> _verifyOtp() async {
    final formatted = _formatPhoneE164(_phoneController.text);
    if (formatted == null) {
      _showError('Invalid phone number.');
      return;
    }
    final token = _otpController.text.trim();
    if (token.isEmpty) {
      _showError('Enter the code from SMS.');
      return;
    }

    final enteredName = _nameController.text.trim();
    setState(() => _isSubmitting = true);
    try {
      await Supabase.instance.client.auth.verifyOTP(
        phone: formatted,
        token: token,
        type: OtpType.sms,
      );
      // Force-update metadata so returning users get the name they just typed,
      // not the name from their first ever signup (signInWithOtp data: is ignored
      // for existing users).
      if (enteredName.isNotEmpty) {
        try {
          await Supabase.instance.client.auth.updateUser(
            UserAttributes(data: {'full_name': enteredName}),
          );
        } catch (_) {}
      }
      // Upsert profiles table immediately with the typed name.
      // This must happen here — not in HomeScreen._ensureProfile() — because
      // onAuthStateChange fires concurrently with updateUser, so _ensureProfile
      // can read stale metadata and overwrite the profile with the old name.
      final uid = Supabase.instance.client.auth.currentUser?.id;
      final phone = Supabase.instance.client.auth.currentUser?.phone;
      if (uid != null) {
        try {
          await Supabase.instance.client.from('profiles').upsert({
            'id': uid,
            'full_name': enteredName.isNotEmpty ? enteredName : null,
            'phone': phone,
          }, onConflict: 'id');
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      if (Supabase.instance.client.auth.currentUser != null) {
        // AuthShell switches to HomeScreen via onAuthStateChange.
      } else {
        _showError('Verification failed.');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError(e.message);
    } catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError('Could not verify OTP.');
    }
  }

  void _resetPhoneStep() {
    setState(() {
      _isOtpSent = false;
      _otpController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SentraDesign.pureWhite,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'SENTRA',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    height: 1.22,
                    color: SentraDesign.uberBlack,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in with your phone',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                    color: SentraDesign.bodyGray,
                  ),
                ),
                const SizedBox(height: 40),
                Text(
                  'Full name',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: SentraDesign.bodyGray,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nameController,
                  enabled: !_isOtpSent,
                  textCapitalization: TextCapitalization.words,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: SentraDesign.uberBlack,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Your name',
                    hintStyle: GoogleFonts.inter(color: SentraDesign.mutedGray),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Name is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                Text(
                  'Phone number',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: SentraDesign.bodyGray,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _phoneController,
                  enabled: !_isOtpSent,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
                  ],
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: SentraDesign.uberBlack,
                  ),
                  decoration: InputDecoration(
                    hintText: '+91 or 10-digit number',
                    hintStyle: GoogleFonts.inter(color: SentraDesign.mutedGray),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Phone is required';
                    }
                    if (_formatPhoneE164(v) == null) {
                      return 'Invalid phone number';
                    }
                    return null;
                  },
                ),
                if (_isOtpSent) ...[
                  const SizedBox(height: 20),
                  Text(
                    'One-time code',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: SentraDesign.bodyGray,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _otpController,
                    keyboardType: TextInputType.number,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: SentraDesign.uberBlack,
                    ),
                    decoration: InputDecoration(
                      hintText: 'SMS code',
                      hintStyle:
                          GoogleFonts.inter(color: SentraDesign.mutedGray),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isSubmitting
                        ? null
                        : (_isOtpSent ? _verifyOtp : _sendOtp),
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: SentraDesign.pureWhite,
                            ),
                          )
                        : Text(_isOtpSent ? 'Verify' : 'Send OTP'),
                  ),
                ),
                if (_isOtpSent) ...[
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed:
                        _isSubmitting ? null : _resetPhoneStep,
                    child: Text(
                      'Change number',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: SentraDesign.uberBlack,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
