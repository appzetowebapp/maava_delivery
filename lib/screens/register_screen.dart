
import 'package:flutter/material.dart';
import 'package:webview_master_app/screens/webview_screen.dart';
import 'package:webview_master_app/config/app_config.dart';

class RegisterScreen extends StatefulWidget {
  final String email;
  final String name;

  const RegisterScreen({
    super.key,
    required this.email,
    required this.name,
  });

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  final _phoneController = TextEditingController();

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    _emailController = TextEditingController(text: widget.email);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (_formKey.currentState!.validate()) {
       setState(() => _isLoading = true);
       try {
         // Perform registration API call if needed
         // For now, let's navigate to the WebView after saving the registration details
         // In reality, this would be a POST to the backend
         
         // After successful registration, navigate to the webview
         if (mounted) {
           Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => const WebViewScreen(),
            ),
          );
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Complete Registration'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: AppConfig.defaultPadding,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'One more step...',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                const Text('Please complete your profile details'),
                const SizedBox(height: 40),

                // Name field
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Full Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.isEmpty) ? 'Please enter your name' : null,
                ),
                const SizedBox(height: 20),

                // Email field
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email Address',
                    border: OutlineInputBorder(),
                  ),
                  readOnly: true, // Typically email is fixed from Google
                ),
                const SizedBox(height: 20),

                // Phone field
                TextFormField(
                  controller: _phoneController,
                  decoration: const InputDecoration(
                    labelText: 'Phone Number',
                    border: OutlineInputBorder(),
                    prefixText: '+91 ',
                  ),
                  keyboardType: TextInputType.phone,
                  validator: (v) => (v == null || v.length != 10) ? 'Enter valid 10-digit number' : null,
                ),
                const SizedBox(height: 60),

                // Complete Button
                SizedBox(
                  width: double.infinity,
                  height: AppConfig.buttonHeight,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleRegister,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppConfig.primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppConfig.borderRadius),
                      ),
                    ),
                    child: _isLoading 
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          'Complete Profile',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
