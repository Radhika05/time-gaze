import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timesgaze/firebase_options.dart';
import 'package:timesgaze/screens/google_photos_screen.dart';
import 'package:timesgaze/screens/splash_screen.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_analytics/observer.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:timesgaze/controllers/auth_controller.dart';
import 'package:timesgaze/screens/login_screen.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';

import 'screens/localStoredPhotos.dart';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
  runApp(ProviderScope(child: MyApp(isLoggedIn: isLoggedIn)));
}

class MyApp extends ConsumerStatefulWidget {
  final bool isLoggedIn;
  const MyApp({super.key, required this.isLoggedIn});

  static FirebaseAnalytics analytics = FirebaseAnalytics.instance;
  static FirebaseAnalyticsObserver observer =
      FirebaseAnalyticsObserver(analytics: analytics);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  bool isLoggedIn = false;
  bool isTokenValid = false;

  late InternetConnectionChecker _internetChecker;
  bool _hasInternet = true;
  @override
  void initState() {
    super.initState();
    _initializeApp();

    
    _internetChecker = InternetConnectionChecker()
      ..onStatusChange.listen((status) {
        setState(() {
          _hasInternet = status == InternetConnectionStatus.connected;
        });
      });
  }

  Future<void> getToken(String refreshToken, BuildContext context) async {
    try {
      await ref.read(authControllerProvider).getToken(refreshToken, context);
    } catch (e) {
      print('Error getting token: $e');
    }
  }

  Future<void> _initializeApp() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final docSnapshot = await FirebaseFirestore.instance
            .collection('usersAuthDetails')
            .doc(user.uid)
            .get();

        if (docSnapshot.exists) {
          final data = docSnapshot.data();
          final timestamp = data?['timestamp'];

          if (timestamp != null) {
            final currentTime = DateTime.now().toUtc();
            final tokenTime = DateTime.parse(timestamp);
            final difference = currentTime.difference(tokenTime);

            if (difference.inMinutes < 52) {
              if (mounted) {
                setState(() {
                  isLoggedIn = true;
                  isTokenValid = true;
                });
              }
              // Photos are loaded via the Google Photos Picker on the photos screen.
            } else {
              final refreshToken =
                  await FlutterSecureStorage().read(key: 'refresh_token');
              if (refreshToken != null && mounted) {
                await getToken(refreshToken, context);
              }
            }
          }
        }
      } catch (e) {
        print('Error initializing app: $e');
      }
    }

    if (!isTokenValid) {
      if (mounted) {
        setState(() {
          isLoggedIn = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: <NavigatorObserver>[MyApp.observer],
      title: 'TimesGaze',
      debugShowCheckedModeBanner: false,
      home: 
      //isLoggedIn? GetPhotosFromLocalStorage():
         // ? GooglePhotos(analytics: MyApp.analytics)
           SplashScreen(analytics: MyApp.analytics)
    );
  }
}
