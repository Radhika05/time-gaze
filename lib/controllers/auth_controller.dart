import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timesgaze/login23.dart';
import 'package:timesgaze/repositories/auth_repositories.dart';
import 'package:timesgaze/screens/enable_facebook_screen.dart';
import 'package:timesgaze/screens/google_photos_screen.dart';

final authControllerProvider = Provider((ref) => AuthController(
      authRepository: ref.read(authRepositoryProvider),
    ));

class AuthController {
  final AuthRepository _authRepository;
  AuthController({required AuthRepository authRepository})
      : _authRepository = authRepository;

  initUniLinks() async {
    await _authRepository.initAppLinks();
  }

  getToken(String refreshToken, BuildContext context) async {
    await _authRepository.getToken(refreshToken, context);
  }

  fetchAlbums(String accessToken) async {
    await _authRepository.fetchAlbums(accessToken);
  }

  signInWithGoogle(BuildContext context) async {
    // await  _authRepository.signInWithGoogle(context);
    await _authRepository.authenticate(context);
  }

  // void signInSilently(BuildContext context) async {
  //   await _authRepository.signInSilently(context);
  // }

  // void signInWithFacebook(BuildContext context) {
  //   _authRepository.signInWithFacebook(context);
  // }

  logOut(BuildContext context) async {
    await _authRepository.logOut(context);
  }

  // void logoutFromFacebook(BuildContext context) {
  //   _authRepository.logoutFromFacebook(context);
  // }
}
