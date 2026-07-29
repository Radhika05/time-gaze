import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:timesgaze/common/constants.dart';
import 'package:timesgaze/controllers/auth_controller.dart';
import 'package:timesgaze/screens/google_photos_screen.dart';
import 'package:timesgaze/screens/login_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  final FirebaseAnalytics analytics;
  const SplashScreen({super.key, required this.analytics});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  String _version = '';
  bool _animationDone = false;
  bool _signInChecked = false;
  bool _autoSignInSuccess = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    // Deep-link listener must be set up before navigating anywhere
    ref.read(authControllerProvider).initUniLinks();
    _checkSession();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {}
  }

  Future<void> _checkSession() async {
    final success = await ref.read(authControllerProvider).tryAutoSignIn();
    if (!mounted) return;
    setState(() {
      _autoSignInSuccess = success;
      _signInChecked = true;
    });
    if (_animationDone) _navigate();
  }

  void _onAnimationEnd() {
    setState(() => _animationDone = true);
    if (_signInChecked) _navigate();
  }

  void _navigate() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _autoSignInSuccess
            ? GooglePhotos(analytics: widget.analytics)
            : LoginScreen(analytics: widget.analytics),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deviceheight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: TweenAnimationBuilder<double>(
                onEnd: _onAnimationEnd,
                tween: Tween<double>(
                    begin: deviceheight * 0.1474, end: deviceheight * 0.5),
                curve: Curves.bounceInOut,
                duration: const Duration(seconds: 3),
                builder: (context, value, _) => Image.asset(
                  Constants.logoPath,
                  height: value,
                  width: value,
                ),
              ),
            ),
            // Spinner shown only if animation finished but session check is still running
            if (_animationDone && !_signInChecked)
              Positioned(
                bottom: deviceheight * 0.1,
                child: const CircularProgressIndicator(
                  color: Color.fromARGB(255, 245, 166, 75),
                  strokeWidth: 3,
                ),
              ),
            if (_version.isNotEmpty)
              Positioned(
                bottom: 16,
                child: Text(
                  'v$_version',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
