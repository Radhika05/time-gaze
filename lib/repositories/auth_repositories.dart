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
final islaunchphoto=StateProvider<bool>((ref)=>false);
final userName = StateProvider<String>((ref) => '');
final userUid = StateProvider<String>((ref) => '');
final userEmail = StateProvider<String>((ref) => '');
final photoUrl = StateProvider((ref) => '');

final refreshTokenProvider = StateProvider<String>((ref) => '');
final photosNoInternetProvider = StateProvider<List<String>>((ref) {
  return [];
});
List<String> photosNoInternet = [];
List<Map<String, String>> photosfinal = [];
List<Map<String, String>> photosSilentfinal = [];

final authRepositoryProvider = Provider((ref) => AuthRepository(
    firestore: FirebaseFirestore.instance,
    auth: FirebaseAuth.instance,
    googleSignIn: GoogleSignIn(),
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
  late AppLinks _appLinks; // AppLinks instance

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
    _appLinks = AppLinks(); // Initialize AppLinks

    try {
      // Check if there is a method for getting the initial link.
      final initialLink = await _appLinks.getInitialLink(); // Update this line
      if (initialLink != null) {
        print('Initial link: $initialLink');
        _handleDeepLink(initialLink); // Process the deep link
      } else {
        print('No initial link found.');
      }

      _sub = _appLinks.uriLinkStream.listen((Uri? link) {
        if (link != null) {
          print('Stream link: $link');
          _handleDeepLink(link); // Handle link from stream
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
    final profile = uri.queryParameters['profile'];

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
      await fetchAlbums(accessToken123!);
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
    final storage = FlutterSecureStorage();

    try {
      final callbackUrlScheme = 'timesgaze';
      final result = await FlutterWebAuth.authenticate(
        url: 'https://timesgaze-oauth.vercel.app/auth/google',
        callbackUrlScheme: callbackUrlScheme,
      );
      if (result.isEmpty) {
        print('Authentication canceled by the user');
        Fluttertoast.showToast(
            msg: "Authentication canceled",
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
            backgroundColor: Colors.red,
            textColor: Colors.white,
            fontSize: 16.0);
      }
      final uri = Uri.parse(result);
      final accessTokennew = uri.queryParameters['accessToken'];
      final refreshToken = uri.queryParameters['refreshToken'];

      if (accessTokennew != null && refreshToken != null) {
        await storage.write(key: 'access_token', value: accessTokennew);
        await storage.write(key: 'refresh_token', value: refreshToken);

        final profile = uri.queryParameters['profile'];
        print('Profile Data: $profile');
      } else {
        print('Tokens are missing in the callback URL');
      }
    } catch (e) {
      print('Authentication error: $e');
      // Fluttertoast.showToast(
      //     msg: "Authentication failed",
      //     toastLength: Toast.LENGTH_SHORT,
      //     gravity: ToastGravity.BOTTOM,
      //     backgroundColor: Colors.red,
      //     textColor: Colors.white,
      //     fontSize: 16.0);
      //     return false;
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
    final String url = 'https://oauth2.googleapis.com/token';
    final Map<String, String> headers = {
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    final Map<String, String> body = {
      'client_id':
          'YOUR_GOOGLE_CLIENT_ID',
      'client_secret': 'YOUR_GOOGLE_CLIENT_SECRET',
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    };

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: headers,
        body: body,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        accessToken123 = '${data['access_token']}';
        await FlutterSecureStorage()
            .write(key: 'access_token', value: accessToken123);

        final now = DateTime.now();
        final formattedDate =
            DateFormat('yyyy-MM-dd HH:mm:ss').format(now.toUtc());
        final user = FirebaseAuth.instance.currentUser;

        if (user != null) {
          await FirebaseFirestore.instance
              .collection('usersAuthDetails')
              .doc(user.uid)
              .update({
            'access_token': accessToken123,
            'timestamp': formattedDate,
          });
        }

        await fetchAlbums(accessToken123!);

        if (response.statusCode == 200)
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: ((context) => GooglePhotos(
                      analytics: _analytics,
                    ))),
          );
        // Fluttertoast.showToast(
        //     msg: "Google Signed In successfully!",
        //     toastLength: Toast.LENGTH_SHORT,
        //     gravity: ToastGravity.BOTTOM,
        //     timeInSecForIosWeb: 5,
        //     backgroundColor: Colors.orange,
        //     textColor: Colors.white,
        //     fontSize: 16.0);
      } else {
        print('Error: ${response.statusCode}');
        print('Response body: ${response.body}');
      }
    } catch (e) {
      print('Exception: $e');
    }
  }

  signInSilently(BuildContext context) async {
    final GoogleSignInAccount? googleSignInAccount =
        await _googleSignIn.signInSilently();

    if (googleSignInAccount != null) {
      currentUser = googleSignInAccount;
      await fetchAlbums('');
    }
  }

  Future<void> fetchAlbums(String accessToken) async {
    final authHeaders = {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    };
    try {
      var res = await http.get(
          Uri.parse('https://photoslibrary.googleapis.com/v1/albums'),
          headers: authHeaders);
      final result = json.decode(res.body);
      photosfinal = [];
      ref.watch(photosAppProvider.notifier).update((state) => photosfinal);
      print(ref.read(photosAppProvider));
      if (result.containsKey('albums') && result['albums'] is List) {
        for (var album in result['albums']) {
          final albumId = album['id'];
          // print(albumId);
          await fetchPhotosForAlbum(albumId, authHeaders);
        }
        for (int j = 0; j < photosfinal.length && j < 50; j++) {
          String baseUrl = photosfinal[j]['baseUrl']!;

          // Download and save the image
          String savedFilePath = await downloadAndSaveImage(baseUrl, j);
          print("saved: $savedFilePath");

          // Store the file path in photosNoInternet if not null
          if (savedFilePath != null) {
            photosNoInternet.add(savedFilePath);
            // Store the file path in localPhotos
          }
        }
        ref
            .watch(photosNoInternetProvider.notifier)
            .update((state) => photosNoInternet);
      } else {
        print('No albums found.');
      }
    } catch (e) {
      print('Error fetching albums: $e');
    }
  }

  logOut(BuildContext context) {
    ref.watch(photosAppProvider.notifier).update((state) => []);
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

  Future<void> fetchPhotosForAlbum(
      String albumId, Map<String, String> authHeaders) async {
    try {
      String nextPageToken = '';

      do {
        final url = Uri.parse(
            'https://photoslibrary.googleapis.com/v1/mediaItems:search?pageToken=$nextPageToken');
        final response = await http.post(
          url,
          headers: authHeaders,
          body: jsonEncode({
            "albumId": albumId,
          }),
        );
        final result = json.decode(response.body);

        if (result.containsKey('mediaItems') && result['mediaItems'] is List) {
          for (var i in result['mediaItems']) {
            photosfinal.add({
              'baseUrl': i['baseUrl'],
              'creationTime': i['mediaMetadata']['creationTime'],
            });

            ref
                .watch(photosAppProvider.notifier)
                .update((state) => photosfinal);

            photosSilentfinal.add({
              'baseUrl': i['baseUrl'],
              'creationTime': i['mediaMetadata']['creationTime'],
            });
            int baseUrlCount = photosfinal
                .where((photo) => photo.containsKey('baseUrl'))
                .length;
            print('Total baseUrls: $baseUrlCount');

            //print(photosfinal.length);
            //print(photosfinal);
            // print(i['mediaMetadata']['creationTime']);
          }
        }

        nextPageToken = result['nextPageToken'] ?? '';
      } while (nextPageToken.isNotEmpty);
    } catch (e) {
      print('Error fetching photos for album $albumId: $e');
    }
  }
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
    // Get local path for storage
    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/photo_$index.jpg';

    // Download image
    final response = await http.get(Uri.parse(url));
    final file = File(filePath);

    // Save image locally
    await file.writeAsBytes(response.bodyBytes);

    print('Photo saved at $filePath');
    return filePath; // Return the file path where the image was saved
  } catch (e) {
    print('Error saving photo: $e');
    return ''; // Return null if there's an error
  }
}
