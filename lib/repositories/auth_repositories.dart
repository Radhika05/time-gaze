import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth/flutter_web_auth.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timesgaze/screens/google_photos_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:timesgaze/screens/login_screen.dart';
import 'package:url_launcher/url_launcher.dart';

final googlephotosProvider = StateProvider<List<String>>((ref) {
  return [];
});

final fbphotosProvider = StateProvider<List<String>>((ref) {
  return [];
});
GoogleSignInAccount? currentUser;
final currentUserGoogle = StateProvider<String>((ref) => '');
final albumEmpty = StateProvider<bool>((ref) => true);
final photosSilentProvider = StateProvider<List<Map<String, String>>>((ref) {
  return [];
});

final photosAppProvider = StateProvider<List<Map<String, String>>>((ref) {
  return [];
});

final defaultPhotos = StateProvider<String>((ref) => 'Last In');
final LpfSelect = StateProvider<int>((ref) => 0);
final islaunchphoto = StateProvider<bool>((ref) => false);
final userName = StateProvider<String>((ref) => '');
final userUid = StateProvider<String>((ref) => '');
final userEmail = StateProvider<String>((ref) => '');
final photoUrl = StateProvider((ref) => '');

final refreshTokenProvider = StateProvider<String>((ref) => '');
final photosNoInternetProvider = StateProvider<List<String>>((ref) {
  return [];
});

final isFetchingPhotosProvider = StateProvider<bool>((ref) => false);

// Stores active picker session: {'sessionId': '...', 'pickerUri': '...'}
final pickerSessionProvider = StateProvider<Map<String, String>?>((ref) => null);

List<String> photosNoInternet = [];
List<Map<String, String>> photosfinal = [];
List<Map<String, String>> photosSilentfinal = [];

final authRepositoryProvider = Provider((ref) => AuthRepository(
    firestore: FirebaseFirestore.instance,
    auth: FirebaseAuth.instance,
    googleSignIn: GoogleSignIn(
      serverClientId: '989810994749-911j2k5kbmaeoarjruhnuj6r4f7g4d5d.apps.googleusercontent.com',
      scopes: [
        'email',
        'profile',
        'https://www.googleapis.com/auth/photospicker.mediaitems.readonly',
      ],
    ),
    analytics: FirebaseAnalytics.instance,
    ref: ref));

AppLinks? _appLinks;
StreamSubscription<Uri>? _sub;
String? accessToken123 = "";

class AuthRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  GoogleSignIn _googleSignIn;
  ProviderRef ref;
  final FirebaseAnalytics _analytics;
  late AppLinks _appLinks;

  AuthRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
    required GoogleSignIn googleSignIn,
    required FirebaseAnalytics analytics,
    required this.ref,
  })  : _auth = auth,
        _firestore = firestore,
        _analytics = analytics,
        _googleSignIn = googleSignIn;

  Future<void> initAppLinks() async {
    _appLinks = AppLinks();

    try {
      final initialLink = await _appLinks.getInitialLink();
      if (initialLink != null) {
        print('Initial link: $initialLink');
        _handleDeepLink(initialLink);
      } else {
        print('No initial link found.');
      }

      _sub = _appLinks.uriLinkStream.listen((Uri? link) {
        if (link != null) {
          print('Stream link: $link');
          _handleDeepLink(link);
        }
      });
    } on PlatformException catch (e) {
      print('PlatformException: $e');
    }
  }

  void _handleDeepLink(Uri uri) async {
    print('Received deep link: $uri');

    final code = uri.queryParameters['code'];
    final accessToken = uri.queryParameters['accessToken'];
    final refreshToken = uri.queryParameters['refreshToken'];

    if (code != null) {
      print('Received code: $code');
      _handleCodeExchange(code);
    } else {
      print('No code found in deep link.');
    }

    if (accessToken != null) {
      print('Received access token: $accessToken');
      accessToken123 = accessToken;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', true);
      final credential = GoogleAuthProvider.credential(
        accessToken: accessToken123,
        idToken: uri.queryParameters['idToken'],
      );

      UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);

      User? user = userCredential.user;
      if (user != null) {
        final now = DateTime.now();
        final formattedDate =
            DateFormat('yyyy-MM-dd HH:mm:ss').format(now.toUtc());
        await FirebaseFirestore.instance
            .collection('usersAuthDetails')
            .doc(user.uid)
            .set({
          'access_token': accessToken123,
          'timestamp': formattedDate,
          'refreshToken': refreshToken
        });
      }

      ref.watch(userUid.notifier).update((state) => user?.uid ?? '');
      ref.watch(userEmail.notifier).update((state) => user?.email ?? '');
    }

    if (refreshToken != null) {
      ref.watch(refreshTokenProvider.notifier).update((state) => refreshToken);
    }
  }

  Future<void> _handleCodeExchange(String code) async {
    final response = await http.get(
      Uri.parse(
          'https://timesgaze-oauth.vercel.app/auth/google/callback?code=$code'),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      print('Authentication successful!');
      print('Access Token: ${data['accessToken']}');
      print('Refresh Token: ${data['refreshToken']}');
    } else {
      print('Failed to exchange code for tokens: ${response.statusCode}');
      print('Response body: ${response.body}');
    }
  }

  authenticate(BuildContext context) async {
    try {
      await _googleSignIn.disconnect().catchError((_) => null);
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      if (account == null) {
        Fluttertoast.showToast(
            msg: "Sign in canceled",
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
            backgroundColor: Colors.red,
            textColor: Colors.white,
            fontSize: 16.0);
        return;
      }

      final auth = await account.authentication;
      final accessToken = auth.accessToken;
      final idToken = auth.idToken;

      print('accessToken: ${accessToken != null ? "present" : "NULL"}');
      print('idToken: ${idToken != null ? "present" : "NULL"}');

      if (accessToken == null) {
        print('No access token received');
        return;
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: accessToken,
        idToken: idToken,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCredential.user;

      if (user != null) {
        final now = DateTime.now();
        final formattedDate =
            DateFormat('yyyy-MM-dd HH:mm:ss').format(now.toUtc());
        await _firestore.collection('usersAuthDetails').doc(user.uid).set({
          'access_token': accessToken,
          'timestamp': formattedDate,
        });
        await FlutterSecureStorage()
            .write(key: 'access_token', value: accessToken);

        ref.read(userUid.notifier).state = user.uid;
        ref.read(userEmail.notifier).state = user.email ?? '';
      }
    } catch (e) {
      print('Authentication error: $e');
      Fluttertoast.showToast(
          msg: "Error: ${e.toString()}",
          toastLength: Toast.LENGTH_LONG,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.red,
          textColor: Colors.white,
          fontSize: 14.0);
    }
  }

  Future<String?> _getStoredAccessToken() async {
    final storage = FlutterSecureStorage();
    String? accessToken = await storage.read(key: 'access_token');
    return accessToken;
  }

  Future<String?> _getStoredRefreshToken() async {
    final storage = FlutterSecureStorage();
    String? refreshToken = await storage.read(key: 'refresh_token');
    return refreshToken;
  }

  getToken(String refreshToken, BuildContext context) async {
    try {
      final account = await _googleSignIn.signInSilently() ??
          await _googleSignIn.signIn();
      if (account == null) return;

      final auth = await account.authentication;
      final accessToken = auth.accessToken;
      if (accessToken == null) return;

      await FlutterSecureStorage()
          .write(key: 'access_token', value: accessToken);

      final now = DateTime.now();
      final formattedDate =
          DateFormat('yyyy-MM-dd HH:mm:ss').format(now.toUtc());
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _firestore
            .collection('usersAuthDetails')
            .doc(user.uid)
            .update({'access_token': accessToken, 'timestamp': formattedDate});
      }

      if (context.mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
              builder: (context) => GooglePhotos(analytics: _analytics)),
        );
      }
    } catch (e) {
      print('Exception: $e');
    }
  }

  signInSilently(BuildContext context) async {
    final account = await _googleSignIn.signInSilently();
    if (account != null) {
      currentUser = account;
      final auth = await account.authentication;
      if (auth.accessToken != null) {
        await FlutterSecureStorage()
            .write(key: 'access_token', value: auth.accessToken!);
      }
    }
  }

  /// Gets a fresh access token via silent sign-in, ensuring it has the Picker scope.
  Future<String?> getFreshAccessToken() async {
    try {
      final account = await _googleSignIn.signInSilently(reAuthenticate: true) ??
          await _googleSignIn.signIn();
      if (account == null) return null;
      final auth = await account.authentication;
      if (auth.accessToken != null) {
        // Update stored token
        await FlutterSecureStorage()
            .write(key: 'access_token', value: auth.accessToken!);
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          final now = DateTime.now();
          await _firestore.collection('usersAuthDetails').doc(user.uid).update({
            'access_token': auth.accessToken!,
            'timestamp': DateFormat('yyyy-MM-dd HH:mm:ss').format(now.toUtc()),
          });
        }
      }
      return auth.accessToken;
    } catch (e) {
      print('Error getting fresh access token: $e');
      return null;
    }
  }

  /// Creates a Google Photos Picker session and opens the picker in the browser.
  /// Returns the session map with 'sessionId' and 'pickerUri', or null on failure.
  /// Throws a [PickerApiException] with a user-facing message on API errors.
  Future<Map<String, String>?> createPickerSession(String accessToken) async {
    try {
      final response = await http.post(
        Uri.parse('https://photospicker.googleapis.com/v1/sessions'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
      );
      print('Picker session status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final sessionId = data['id'] as String;
        print('Picker session id: $sessionId');
        final session = {
          'sessionId': sessionId,
          'pickerUri': data['pickerUri'] as String,
        };
        ref.read(pickerSessionProvider.notifier).state = session;

        await launchUrl(
          Uri.parse(session['pickerUri']!),
          mode: LaunchMode.externalApplication,
        );
        return session;
      } else if (response.statusCode == 404) {
        print('Picker API 404 — API not enabled. Body: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
        throw PickerApiException(
          'Google Photos Picker API is not enabled in your Google Cloud Console project. '
          'Go to APIs & Services → Library → search "Photos Picker API" → Enable it.',
        );
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        print('Picker API ${response.statusCode}. Body: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
        throw PickerApiException(
          'Access denied (${response.statusCode}). Sign out and sign in again to grant the required permission.',
        );
      } else {
        print('Picker session error ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
        throw PickerApiException('Failed to open photo picker (${response.statusCode}). Please try again.');
      }
    } on PickerApiException {
      rethrow;
    } catch (e) {
      print('Error creating picker session: $e');
      throw PickerApiException('Could not open photo picker: $e');
    }
  }

  /// Polls the picker session and fetches selected media items.
  /// Returns true if photos were loaded, false if no selection was made yet.
  Future<bool> fetchPickerMediaItems(
      String sessionId, String accessToken) async {
    final authHeaders = {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    };

    ref.read(isFetchingPhotosProvider.notifier).state = true;
    try {
      final sessionResponse = await http.get(
        Uri.parse('https://photospicker.googleapis.com/v1/sessions/$sessionId'),
        headers: authHeaders,
      );
      print('Session poll status: ${sessionResponse.statusCode}');
      final sessionData = json.decode(sessionResponse.body);

      if (sessionData['mediaItemsSet'] != true) {
        print('No items selected yet.');
        return false;
      }

      photosfinal = [];
      ref.read(photosAppProvider.notifier).state = [];

      String nextPageToken = '';
      do {
        final queryParams = {
          'sessionId': sessionId,
          'pageSize': '100',
          if (nextPageToken.isNotEmpty) 'pageToken': nextPageToken,
        };
        final url = Uri.https(
          'photospicker.googleapis.com',
          '/v1/mediaItems',
          queryParams,
        );
        final response = await http.get(url, headers: authHeaders);
        print('Picker items status: ${response.statusCode}');

        if (response.statusCode != 200) {
          print('Picker items error: ${response.body}');
          break;
        }

        final result = json.decode(response.body);
        if (result['mediaItems'] is List) {
          for (var item in result['mediaItems']) {
            final mediaFile = item['mediaFile'];
            if (mediaFile?['baseUrl'] != null) {
              photosfinal.add({
                'baseUrl': '${mediaFile['baseUrl']}=w2048-h2048',
                'creationTime': item['createTime'] ??
                    DateTime.now().toIso8601String(),
              });
            }
          }
          ref.read(photosAppProvider.notifier).state = List.from(photosfinal);
        }
        nextPageToken = result['nextPageToken'] ?? '';
      } while (nextPageToken.isNotEmpty);

      // Cache for offline use
      photosNoInternet = [];
      for (int j = 0; j < photosfinal.length && j < 50; j++) {
        final path =
            await downloadAndSaveImage(photosfinal[j]['baseUrl']!, j);
        if (path.isNotEmpty) photosNoInternet.add(path);
      }
      ref.read(photosNoInternetProvider.notifier).state =
          List.from(photosNoInternet);

      // Clean up the session
      await http.delete(
        Uri.parse('https://photospicker.googleapis.com/v1/sessions/$sessionId'),
        headers: authHeaders,
      );
      ref.read(pickerSessionProvider.notifier).state = null;

      return photosfinal.isNotEmpty;
    } catch (e) {
      print('Error fetching picker items: $e');
      return false;
    } finally {
      ref.read(isFetchingPhotosProvider.notifier).state = false;
    }
  }

  logOut(BuildContext context) {
    ref.watch(photosAppProvider.notifier).update((state) => []);
    ref.read(pickerSessionProvider.notifier).state = null;
    photosfinal = [];
    print(ref.read(photosAppProvider));
    GoogleSignIn? googleSignIn = GoogleSignIn();

    googleSignIn.signOut();
    _auth.signOut();

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
          builder: (context) => LoginScreen(
                analytics: _analytics,
              )),
      (Route<dynamic> route) => false,
    );
  }
}

class PickerApiException implements Exception {
  final String message;
  PickerApiException(this.message);
  @override
  String toString() => message;
}

void showLoadingScreen(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return Dialog(
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/load.gif'),
              SizedBox(height: 20),
              Text("Configuring your Device..."),
            ],
          ),
        ),
      );
    },
  );
}

Future<String> downloadAndSaveImage(String url, int index) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/photo_$index.jpg';

    final response = await http.get(Uri.parse(url));
    final file = File(filePath);

    await file.writeAsBytes(response.bodyBytes);

    print('Photo saved at $filePath');
    return filePath;
  } catch (e) {
    print('Error saving photo: $e');
    return '';
  }
}
