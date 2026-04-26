
import 'package:flutter/material.dart';
import 'package:webview_master_app/services/auth_service.dart';
import 'package:webview_master_app/screens/register_screen.dart';
import 'package:webview_master_app/screens/webview_screen.dart';
import 'package:webview_master_app/config/app_config.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final credential = await AuthService().signInWithGoogle();
      if (credential != null && credential.user != null) {
        // Redirect based on whether the user is new or existing
        final isNewUser = credential.additionalUserInfo?.isNewUser ?? false;

        if (mounted) {
          if (isNewUser) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => RegisterScreen(
                  email: credential.user!.email ?? '',
                  name: credential.user!.displayName ?? '',
                ),
              ),
            );
          } else {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (context) => const WebViewScreen()),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sign-in failed or cancelled')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: AppConfig.defaultPadding,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo
              Image.asset(
                AppConfig.appLogoPath,
                height: 120,
              ),
              const SizedBox(height: 40),
              
              const Text(
                'Welcome Back',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Please sign in to continue',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 60),

              // Google Sign In Button
              SizedBox(
                width: double.infinity,
                height: AppConfig.buttonHeight,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _handleGoogleSignIn,
                  icon: _isLoading 
                    ? const SizedBox(
                        width: 20, 
                        height: 20, 
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Image.network(
                        'https://upload.wikimedia.org/wikipedia/commons/c/c1/Google_%22G%22_logo.svg',
                        height: 24,
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.login),
                      ),
                  label: const Text(
                    'Sign in with Google',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppConfig.borderRadius),
                      side: const BorderSide(color: Colors.grey, width: 0.5),
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 20),
              
              // Skip/Webview bypass
              TextButton(
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (context) => const WebViewScreen()),
                  );
                },
                child: const Text('Continue as Guest'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
