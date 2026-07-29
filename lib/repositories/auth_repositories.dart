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
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timesgaze/common/app_logger.dart';
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

// Album save progress: (photosDownloaded, totalPhotos) — null when not saving
final albumSaveProgressProvider =
    StateProvider<(int, int)?>((ref) => null);

class PickerAlbum {
  final String id;
  final String name;
  final String? thumbnailPath;
  final List<String> photoPaths;
  final DateTime createdAt;
  final bool isEnabled;
  final List<int> disabledPhotoIndices;

  const PickerAlbum({
    required this.id,
    required this.name,
    this.thumbnailPath,
    required this.photoPaths,
    required this.createdAt,
    this.isEnabled = true,
    this.disabledPhotoIndices = const [],
  });

  PickerAlbum copyWith({bool? isEnabled, List<int>? disabledPhotoIndices}) =>
      PickerAlbum(
        id: id,
        name: name,
        thumbnailPath: thumbnailPath,
        photoPaths: photoPaths,
        createdAt: createdAt,
        isEnabled: isEnabled ?? this.isEnabled,
        disabledPhotoIndices: disabledPhotoIndices ?? this.disabledPhotoIndices,
      );

  int get enabledPhotoCount =>
      photoPaths.length - disabledPhotoIndices.length;

  List<String> get enabledPhotoPaths {
    if (disabledPhotoIndices.isEmpty) return List.from(photoPaths);
    final disabled = Set<int>.from(disabledPhotoIndices);
    return [
      for (int i = 0; i < photoPaths.length; i++)
        if (!disabled.contains(i)) photoPaths[i],
    ];
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'thumbnailPath': thumbnailPath,
        'photoPaths': photoPaths,
        'createdAt': createdAt.toIso8601String(),
        'isEnabled': isEnabled,
        'disabledPhotoIndices': disabledPhotoIndices,
      };

  factory PickerAlbum.fromJson(Map<String, dynamic> json) => PickerAlbum(
        id: json['id'] as String,
        name: json['name'] as String,
        thumbnailPath: json['thumbnailPath'] as String?,
        photoPaths: List<String>.from(json['photoPaths'] as List),
        createdAt: DateTime.parse(json['createdAt'] as String),
        isEnabled: json['isEnabled'] as bool? ?? true,
        disabledPhotoIndices: json['disabledPhotoIndices'] != null
            ? List<int>.from(json['disabledPhotoIndices'] as List)
            : const [],
      );
}

final pickerAlbumsProvider = StateProvider<List<PickerAlbum>>((ref) => []);

List<String> photosNoInternet = [];
List<Map<String, String>> photosfinal = [];
List<Map<String, String>> photosSilentfinal = [];

final authRepositoryProvider = Provider((ref) => AuthRepository(
    firestore: FirebaseFirestore.instance,
    auth: FirebaseAuth.instance,
    googleSignIn: GoogleSignIn(
      serverClientId: '540161251770-9glr2ct9mk8nhd1kqth7rva8vmqtknco.apps.googleusercontent.com',
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

  static const String _albumsPrefsKey = 'picker_albums_v2';
  static const String _pickerSessionPrefsKey = 'picker_session_v1';

  /// Persists the in-progress picker session so it survives the app process
  /// being killed while backgrounded (common on many Android OEMs while the
  /// external browser is in the foreground for photo selection).
  Future<void> _persistPickerSession(Map<String, String> session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pickerSessionPrefsKey, json.encode(session));
  }

  Future<void> _clearPersistedPickerSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pickerSessionPrefsKey);
  }

  /// Restores a picker session left over from before the app process was
  /// killed, so the UI can re-show the "I've selected my photos" fallback
  /// (or an auto-check can be attempted) instead of looking like nothing
  /// happened after the user picked photos in the browser.
  Future<Map<String, String>?> restorePickerSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pickerSessionPrefsKey);
    if (raw == null) return null;
    try {
      final session = Map<String, String>.from(json.decode(raw));
      ref.read(pickerSessionProvider.notifier).state = session;
      return session;
    } catch (e) {
      AppLogger.e('Error restoring picker session', error: e);
      await _clearPersistedPickerSession();
      return null;
    }
  }

  Future<List<PickerAlbum>> loadPickerAlbums() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_albumsPrefsKey);
      if (raw == null) {
        ref.read(pickerAlbumsProvider.notifier).state = [];
        return [];
      }
      final list = (json.decode(raw) as List)
          .map((e) => PickerAlbum.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final valid = list
          .where((a) =>
              a.photoPaths.isNotEmpty && File(a.photoPaths.first).existsSync())
          .toList();
      if (valid.length < list.length) {
        AppLogger.w(
            'Dropped ${list.length - valid.length} album(s) with missing files');
      }
      ref.read(pickerAlbumsProvider.notifier).state = valid;
      AppLogger.d('Loaded ${valid.length} album(s)');
      return valid;
    } catch (e, st) {
      AppLogger.e('Failed to load albums from prefs', error: e, stackTrace: st);
      ref.read(pickerAlbumsProvider.notifier).state = [];
      return [];
    }
  }

  Future<PickerAlbum?> saveCurrentPhotosAsAlbum(
      String name, String? accessToken) async {
    if (photosfinal.isEmpty) return null;

    final albumId = DateTime.now().millisecondsSinceEpoch.toString();
    final directory = await getApplicationDocumentsDirectory();
    final albumDir = Directory('${directory.path}/albums/$albumId');
    await albumDir.create(recursive: true);

    final headers = accessToken != null
        ? {'Authorization': 'Bearer $accessToken'}
        : <String, String>{};

    ref.read(albumSaveProgressProvider.notifier).state =
        (0, photosfinal.length);

    final photoPaths = <String>[];
    int failedCount = 0;
    try {
      for (int i = 0; i < photosfinal.length; i++) {
        final url = photosfinal[i]['baseUrl']!;
        final filePath = '${albumDir.path}/$i.jpg';
        try {
          final response = await http
              .get(Uri.parse(url), headers: headers)
              .timeout(const Duration(seconds: 30));
          if (response.statusCode == 200) {
            await File(filePath).writeAsBytes(response.bodyBytes);
            photoPaths.add(filePath);
          } else {
            AppLogger.w('Photo $i download returned ${response.statusCode}');
            failedCount++;
          }
        } catch (e) {
          AppLogger.w('Photo $i download failed', error: e);
          failedCount++;
        }
        ref.read(albumSaveProgressProvider.notifier).state =
            (i + 1, photosfinal.length);
      }
    } finally {
      ref.read(albumSaveProgressProvider.notifier).state = null;
    }
    if (failedCount > 0) {
      AppLogger.w(
          '$failedCount of ${photosfinal.length} photo(s) failed to download');
    }

    if (photoPaths.isEmpty) {
      await albumDir.delete(recursive: true);
      return null;
    }

    final album = PickerAlbum(
      id: albumId,
      name: name,
      thumbnailPath: photoPaths.first,
      photoPaths: photoPaths,
      createdAt: DateTime.now(),
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_albumsPrefsKey);
    final existing = raw != null
        ? (json.decode(raw) as List)
            .map((e) =>
                PickerAlbum.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList()
        : <PickerAlbum>[];
    existing.add(album);
    await prefs.setString(
      _albumsPrefsKey,
      json.encode(existing.map((a) => a.toJson()).toList()),
    );
    ref.read(pickerAlbumsProvider.notifier).state = List.from(existing);
    return album;
  }

  void loadAlbumPhotos(PickerAlbum album) {
    final photos = album.photoPaths
        .map((p) => {
              'baseUrl': p,
              'creationTime': album.createdAt.toIso8601String(),
            })
        .toList();
    photosfinal = photos;
    ref.read(photosAppProvider.notifier).state = List.from(photos);
    ref.read(photosNoInternetProvider.notifier).state =
        List.from(album.photoPaths);
  }

  Future<void> deletePickerAlbum(String albumId) async {
    final directory = await getApplicationDocumentsDirectory();
    final albumDir = Directory('${directory.path}/albums/$albumId');
    if (await albumDir.exists()) {
      await albumDir.delete(recursive: true);
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_albumsPrefsKey);
    if (raw == null) return;

    final updated = (json.decode(raw) as List)
        .map((e) => PickerAlbum.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((a) => a.id != albumId)
        .toList();
    await prefs.setString(
      _albumsPrefsKey,
      json.encode(updated.map((a) => a.toJson()).toList()),
    );
    ref.read(pickerAlbumsProvider.notifier).state = updated;
  }

  Future<void> updateAlbumEnabled(String albumId, bool isEnabled) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_albumsPrefsKey);
    if (raw == null) return;
    final updated = (json.decode(raw) as List)
        .map((e) => PickerAlbum.fromJson(Map<String, dynamic>.from(e as Map)))
        .map((a) => a.id == albumId ? a.copyWith(isEnabled: isEnabled) : a)
        .toList();
    await prefs.setString(
        _albumsPrefsKey, json.encode(updated.map((a) => a.toJson()).toList()));
    ref.read(pickerAlbumsProvider.notifier).state = updated;
  }

  Future<void> updatePhotoSelection(
      String albumId, List<int> disabledIndices) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_albumsPrefsKey);
    if (raw == null) return;
    final updated = (json.decode(raw) as List)
        .map((e) => PickerAlbum.fromJson(Map<String, dynamic>.from(e as Map)))
        .map((a) =>
            a.id == albumId ? a.copyWith(disabledPhotoIndices: disabledIndices) : a)
        .toList();
    await prefs.setString(
        _albumsPrefsKey, json.encode(updated.map((a) => a.toJson()).toList()));
    ref.read(pickerAlbumsProvider.notifier).state = updated;
  }

  void loadSelectedPhotos() {
    final albums = ref.read(pickerAlbumsProvider);
    final photos = <Map<String, String>>[];
    for (final album in albums) {
      if (!album.isEnabled) continue;
      for (final path in album.enabledPhotoPaths) {
        photos.add({
          'baseUrl': path,
          'creationTime': album.createdAt.toIso8601String(),
        });
      }
    }
    photosfinal = photos;
    ref.read(photosAppProvider.notifier).state = List.from(photos);
    ref.read(photosNoInternetProvider.notifier).state =
        photos.map((p) => p['baseUrl']!).toList();
  }

  /// Attempts a silent Google sign-in using the existing Firebase session.
  /// Returns true if a fresh access token was obtained (user can skip login).
  Future<bool> tryAutoSignIn() async {
    try {
      // `_auth.currentUser` can still be null right after app start even for
      // an already-logged-in user: Firebase Auth restores the persisted
      // session asynchronously after Firebase.initializeApp() completes, and
      // there's no guarantee that restore has landed yet. Waiting for the
      // first authStateChanges() event (bounded by a timeout, in case the
      // user really is signed out) avoids intermittently missing the
      // existing login.
      final firebaseUser = _auth.currentUser ??
          await _auth.authStateChanges().first.timeout(
                const Duration(seconds: 5),
                onTimeout: () => null,
              );
      if (firebaseUser == null) {
        AppLogger.d('Auto sign-in: no Firebase session');
        return false;
      }

      final account = await _googleSignIn.signInSilently();
      if (account == null) {
        AppLogger.d('Auto sign-in: silent sign-in returned null');
        return false;
      }

      final auth = await account.authentication;
      final accessToken = auth.accessToken;
      if (accessToken == null) {
        AppLogger.d('Auto sign-in: no access token');
        return false;
      }

      await FlutterSecureStorage()
          .write(key: 'access_token', value: accessToken);
      final timestamp =
          DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now().toUtc());
      await _firestore
          .collection('usersAuthDetails')
          .doc(firebaseUser.uid)
          .update({'access_token': accessToken, 'timestamp': timestamp});

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', true);

      ref.read(userUid.notifier).state = firebaseUser.uid;
      ref.read(userEmail.notifier).state = firebaseUser.email ?? '';

      AppLogger.i('Auto sign-in OK: ${firebaseUser.email}');
      return true;
    } catch (e) {
      AppLogger.w('Auto sign-in failed', error: e);
      return false;
    }
  }

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
      // Use cached user first to avoid unnecessary re-auth prompts
      GoogleSignInAccount? account = _googleSignIn.currentUser;
      account ??= await _googleSignIn.signInSilently();
      account ??= await _googleSignIn.signIn();
      if (account == null) {
        AppLogger.w('getFreshAccessToken: no account obtained');
        return null;
      }
      final auth = await account.authentication;
      if (auth.accessToken == null) {
        AppLogger.w('getFreshAccessToken: accessToken is null for ${account.email}');
        return null;
      }
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
      return auth.accessToken;
    } catch (e) {
      AppLogger.e('Error getting fresh access token', error: e);
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
        await _persistPickerSession(session);

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

      // Clean up the session
      await http.delete(
        Uri.parse('https://photospicker.googleapis.com/v1/sessions/$sessionId'),
        headers: authHeaders,
      );
      ref.read(pickerSessionProvider.notifier).state = null;
      await _clearPersistedPickerSession();

      return photosfinal.isNotEmpty;
    } catch (e) {
      print('Error fetching picker items: $e');
      return false;
    } finally {
      ref.read(isFetchingPhotosProvider.notifier).state = false;
    }
  }

  Future<void> logOut(BuildContext context) async {
    // Clear all in-memory state
    ref.read(photosAppProvider.notifier).state = [];
    ref.read(pickerSessionProvider.notifier).state = null;
    ref.read(pickerAlbumsProvider.notifier).state = [];
    photosfinal = [];
    await _clearPersistedPickerSession();

    // disconnect() revokes app access and clears the cached account so the
    // account-picker appears on the next sign-in (enables switching accounts)
    try {
      await _googleSignIn.disconnect();
    } catch (e) {
      AppLogger.w('Google disconnect error (non-fatal)', error: e);
    }
    await _auth.signOut();

    // Clear stored credentials
    const storage = FlutterSecureStorage();
    await storage.delete(key: 'access_token');
    await storage.delete(key: 'refresh_token');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', false);

    AppLogger.i('User signed out');

    if (context.mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
            builder: (context) => LoginScreen(analytics: _analytics)),
        (Route<dynamic> route) => false,
      );
    }
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
