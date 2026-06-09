import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logger/logger.dart';
import 'package:timesgaze/common/constants.dart';
import 'package:timesgaze/controllers/auth_controller.dart';
import 'package:timesgaze/repositories/auth_repositories.dart';
import 'package:timesgaze/screens/enable_facebook_screen.dart';
import 'package:timesgaze/screens/google_photos_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  final FirebaseAnalytics analytics;
  const LoginScreen({super.key, required this.analytics});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final logger = Logger();

  void _logButtonPress() {
    widget.analytics.logEvent(
      name: 'button_press',
      parameters: <String, dynamic>{
        'button_name': 'example_button',
      },
    );
  }

  void _logLogin() {
    widget.analytics.logLogin(loginMethod: 'email');
  }

  void _logSignUp() {
    widget.analytics.logSignUp(signUpMethod: 'email');
  }

  setUserId() {
    print('idddd${ref.read(userUid)}');
    FirebaseAnalytics.instance.setUserId(id: ref.read(userUid));
  }

  void logGoogleSignInEvent() {
    setUserId();
    // analytics.setAnalyticsCollectionEnabled(true);

    widget.analytics.logEvent(
      name: 'User_sign_in_event',
      parameters: <String, dynamic>{
        'method': 'Google',
        // 'user_id': ref.read(userEmail),
        'user_id': 'shree@gmail.com',
        'uid': 'ref.read(userUid)'
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _setCurrentScreen();
  }

  Future<void> _setCurrentScreen() async {
    await widget.analytics.logEvent(
      name: 'screen_view',
      parameters: <String, dynamic>{
        'screen_name': 'LoginScreen',
        'screen_class': 'LoginScreen',
      },
    );
    logger.i("Screen view logged: LoginScreen");
  }

  void signInWithGoogle(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(authControllerProvider).signInWithGoogle(context);
      logGoogleSignInEvent();

      // Navigate immediately — photos load in background with loading spinner
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => GooglePhotos(
            analytics: widget.analytics,
          ),
        ),
      );
      // String logMessage = "Google signed in";
      // logger.i(logMessage);

      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(content: Text(logMessage)),
      // );

      // Navigator.pushReplacement(
      //   context,
      //   MaterialPageRoute(
      //       builder: ((context) => EnableFacebook(
      //           photos: photosfinal, analytics: widget.analytics))),
      // );
    } catch (e) {
      String errorMessage = "Error signing in with Google: ${e.toString()}";
      logger.e(errorMessage);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final devicewidth = MediaQuery.of(context).size.width;
    print(devicewidth);
    final deviceheight = MediaQuery.of(context).size.height;
    return SafeArea(
      child: PopScope(
        canPop: false,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Center(
                child: Container(
                  height: deviceheight * 0.4424,
                  width: devicewidth * 0.6944,
                  child: Image.asset(
                    'assets/images/Logo.jpeg',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              SizedBox(
                height: 0.0295 * deviceheight,
              ),
              Padding(
                padding: EdgeInsets.all(0.0442 * deviceheight),
                child: ElevatedButton.icon(
                  onPressed: () {
                    //  _logButtonPress();
                    signInWithGoogle(context, ref);
                  },
                  icon: Image.asset(
                    Constants.googlePath,
                    width: devicewidth * 0.0972,
                  ),
                  label: Text(
                    'Continue with Google',
                    style: TextStyle(
                        fontSize: deviceheight * 0.0265, color: Colors.black),
                  ),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      minimumSize: Size(
                          devicewidth > 400 ? 500 : double.infinity,
                          deviceheight * 0.0737),
                      shape: RoundedRectangleBorder(
                        side: BorderSide(
                          color: Color.fromARGB(255, 245, 166, 75),
                        ),
                        borderRadius:
                            BorderRadius.circular(0.0295 * deviceheight),
                      )),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void showLoadingScreen(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/images/load.gif'),
                SizedBox(height: 20),
                Text("Retrieving Your Photo Collection...."),
              ],
            ),
          ),
        ),
      );
    },
  );
}
