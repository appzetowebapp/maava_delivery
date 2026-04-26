
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// Get the current Firebase user
  User? get currentUser => _auth.currentUser;

  /// Sign in with Google and return the UserCredential
  Future<UserCredential?> signInWithGoogle() async {
    try {
      // 1. Trigger the Google Authentication flow
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      
      if (googleUser == null) {
        // The user cancelled the sign-in
        debugPrint('⚠️ Google sign-in cancelled by user');
        return null;
      }

      // 2. Obtain the auth details from the request
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      // 3. Create a new credential
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // 4. Sign in to Firebase with the credential
      final UserCredential userCredential = await _auth.signInWithCredential(credential);
      debugPrint('✅ Google sign-in successful for: ${userCredential.user?.email}');
      
      return userCredential;
    } catch (e) {
      debugPrint('❌ Error during Google sign-in: $e');
      return null;
    }
  }



  /// Sign out from Google and Firebase
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      await _auth.signOut();
      debugPrint('✅ Signed out successfully');
    } catch (e) {
      debugPrint('❌ Error during sign out: $e');
    }
  }
}
