import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

/// A beautifully styled dialog that matches the app's dark theme
class StyledDialog extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Color? iconColor;
  final Widget content;
  final List<StyledDialogAction> actions;
  final bool barrierDismissible;

  const StyledDialog({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    required this.content,
    required this.actions,
    this.barrierDismissible = true,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    IconData? icon,
    Color? iconColor,
    required Widget content,
    required List<StyledDialogAction> actions,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: Colors.black.withOpacity(0.8),
      builder: (context) => StyledDialog(
        title: title,
        icon: icon,
        iconColor: iconColor,
        content: content,
        actions: actions,
        barrierDismissible: barrierDismissible,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        constraints: BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.7),
              blurRadius: 20,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            _buildHeader(),
            SizedBox(height: 16),
            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: content,
              ),
            ),

            // Actions
            _buildActions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.1), width: 1),
        ),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (iconColor ?? primaryColor).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor ?? primaryColor, size: 24),
            ),
            SizedBox(width: 16),
          ],
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: actions.length > 2
          ? Wrap(
              alignment: WrapAlignment.start,
              spacing: 12,
              runSpacing: 8,
              children: actions.asMap().entries.map((entry) {
                final action = entry.value;
                final isLast = entry.key == actions.length - 1;
                return _buildActionButton(context, action, isLast);
              }).toList(),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: actions.asMap().entries.map((entry) {
                final index = entry.key;
                final action = entry.value;
                final isLast = index == actions.length - 1;

                return Padding(
                  padding: EdgeInsets.only(left: index > 0 ? 12 : 0),
                  child: _buildActionButton(context, action, isLast),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    StyledDialogAction action,
    bool isPrimary,
  ) {
    if (action.isPrimary || isPrimary && !actions.any((a) => a.isPrimary)) {
      // Primary button with gradient
      return Container(
        decoration: BoxDecoration(
          gradient: action.isDestructive
              ? LinearGradient(
                  colors: [Colors.red.shade700, Colors.red.shade900],
                )
              : primaryGradient,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: action.isLoading ? null : action.onPressed,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: action.isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      action.label,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
            ),
          ),
        ),
      );
    } else {
      // Secondary button
      return TextButton(
        onPressed: action.isLoading ? null : action.onPressed,
        style: TextButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: action.isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: action.color ?? Colors.white.withOpacity(0.7),
                ),
              )
            : Text(
                action.label,
                style: TextStyle(
                  color: action.color ?? Colors.white.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),
      );
    }
  }
}

class StyledDialogAction {
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final bool isDestructive;
  final bool isLoading;
  final Color? color;

  const StyledDialogAction({
    required this.label,
    this.onPressed,
    this.isPrimary = false,
    this.isDestructive = false,
    this.isLoading = false,
    this.color,
  });
}

/// Helper widget for styled text input in dialogs
class StyledDialogTextField extends StatelessWidget {
  final TextEditingController controller;
  final String? hintText;
  final int maxLines;
  final String? errorText;
  final bool obscureText;
  final TextInputType? keyboardType;

  const StyledDialogTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.maxLines = 1,
    this.errorText,
    this.obscureText = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: errorText != null
              ? Colors.red.withOpacity(0.5)
              : Colors.white.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            maxLines: maxLines,
            obscureText: obscureText,
            keyboardType: keyboardType,
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 13,
            ),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: TextStyle(
                color: Colors.white.withOpacity(0.3),
                fontSize: 13,
              ),
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(16),
            ),
          ),
          if (errorText != null)
            Padding(
              padding: EdgeInsets.only(left: 16, bottom: 12),
              child: Text(
                errorText!,
                style: TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Styled seed phrase display box
class StyledSeedPhraseBox extends StatelessWidget {
  final String seedPhrase;
  final VoidCallback? onCopy;
  final bool showCopyButton;

  const StyledSeedPhraseBox({
    super.key,
    required this.seedPhrase,
    this.onCopy,
    this.showCopyButton = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: primaryColor.withOpacity(0.3), width: 1),
      ),
      child: Column(
        children: [
          SelectableText(
            seedPhrase,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.white,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          if (showCopyButton) ...[
            SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: seedPhrase));
                  onCopy?.call();
                },
                icon: Icon(Icons.copy, size: 18),
                label: Text('Copy to Clipboard'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: primaryColor,
                  side: BorderSide(color: primaryColor.withOpacity(0.5)),
                  padding: EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Styled checkbox for dialogs
class StyledDialogCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?> onChanged;
  final String label;

  const StyledDialogCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: value ? primaryColor : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: value ? primaryColor : Colors.white.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: value
                  ? Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
