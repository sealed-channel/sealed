import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  RegisterScreenState createState() => RegisterScreenState();
}

class RegisterScreenState extends ConsumerState {
  RegisterScreenState();
  TextEditingController usernameController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(userProvider);
    final userState = userAsync.value;

    return Scaffold(
      body: userState!.phase == UserPhase.updatingUsername
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: HORIZONTAL_PADDING),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Set your username',
                      style: Theme.of(context).textTheme.headlineMedium!
                          .copyWith(fontWeight: FontWeight.w500, fontSize: 24),
                    ),
                    SizedBox(height: 20),
                    TextField(
                      controller: usernameController,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: cardColor,

                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: primaryColor, width: 1),
                        ),
                        hintText: 'username',
                        hintStyle: TextStyle(
                          color: Colors.grey,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    _ContinueButton(onPressed: _handleRegister),
                  ],
                ),
              ),
            ),
    );
  }

  void _handleRegister() async {
    final username = usernameController.text.trim();

    if (username.isEmpty) {
      context.showError('Please enter a username');
      return;
    }

    if (username.length < 3) {
      context.showError('Username must be at least 3 characters');
      return;
    }

    if (username.length > 20) {
      context.showError('Username must be 20 characters or less');
      return;
    }

    try {
      final notifier = ref.read(userProvider.notifier);
      await notifier.setUsername(username: username);
    } catch (e) {
      if (mounted) {
        context.showRegistrationError(
          RegistrationException.fromError(e).message,
          onRetry: _handleRegister,
        );
      }
    }
  }
}

class _ContinueButton extends StatefulWidget {
  const _ContinueButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<_ContinueButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() {
          _isPressed = true;
        });
      },
      onTapUp: (_) {
        setState(() {
          _isPressed = false;
        });
      },
      onTapCancel: () {
        setState(() {
          _isPressed = false;
        });
      },
      onTap: () => {widget.onPressed()},

      child: AnimatedScale(
        duration: Duration(milliseconds: 100),
        scale: _isPressed ? 0.95 : 1.0,
        child: AnimatedOpacity(
          duration: Duration(milliseconds: 200),
          opacity: _isPressed ? 0.7 : 1.0,

          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),

            decoration: BoxDecoration(
              boxShadow: _isPressed ? [] : [primaryShadow],
              gradient: primaryGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Continue',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
