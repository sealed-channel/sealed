import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/svg.dart';
import 'package:sealed_app/ui/onboarding/screens/how_it_works.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      children: [
        Center(
          child: Text(
            "Welcome to",
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall!.copyWith(color: neutralColor),
          ),
        ),
        Gap(16.h),
        Image.asset("assets/logo.png", width: 180.w),
        Gap(32.h),
        Text(
          "Private messages. Zero surveillance.",
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Gap(8.h),
        Text(
          "End-to-end encrypted. No phone number,  no email, no servers watching.",
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(color: neutralColor),
          textAlign: TextAlign.center,
        ),

        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: SvgPicture.asset(
              "assets/svg/welcome_graphic.svg",
              width: double.infinity,
            ),
          ),
        ),
        SealedCircularButton(
          label: "Continue",
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const HowItWorksFlow()),
            );
          },
        ),
      ],
    );
  }
}
