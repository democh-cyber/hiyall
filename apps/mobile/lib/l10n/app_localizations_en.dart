// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get helpBack => 'Back';

  @override
  String get helpTitle => 'Help & Safety';

  @override
  String get helpIntro =>
      'A real person reads what you send. Tap an address to write to us, or copy it.';

  @override
  String get helpSectionContact => 'Contact us';

  @override
  String get helpContactHelp => 'Help and feedback';

  @override
  String get helpContactSafety => 'Safety concerns';

  @override
  String get helpContactPrivacy => 'Privacy and your data';

  @override
  String get helpMailSubjectHelp => 'Help';

  @override
  String get helpMailSubjectSafety => 'Safety';

  @override
  String get helpMailSubjectPrivacy => 'Privacy';

  @override
  String helpCopyTooltip(String address) {
    return 'Copy $address';
  }

  @override
  String helpCopied(String address) {
    return 'Copied $address';
  }

  @override
  String helpNoMailApp(String address) {
    return 'No mail app here. Copied $address instead.';
  }

  @override
  String get helpSectionStayingSafe => 'Staying safe';

  @override
  String get helpTipKeepInHiyallTitle => 'Keep it in Hiyall at first';

  @override
  String get helpTipKeepInHiyallBody =>
      'Don’t share your phone number, address, school or where you hang out with someone you just met.';

  @override
  String get helpTipPeopleTitle => 'People can pretend';

  @override
  String get helpTipPeopleBody =>
      'Someone may not be who they say. If it feels off, trust that feeling.';

  @override
  String get helpTipPhotoTitle => 'Think before you send a photo';

  @override
  String get helpTipPhotoBody =>
      'A photo can be saved or shared by the person who gets it, even in an encrypted chat.';

  @override
  String get helpTipMeetingTitle => 'Meeting in person';

  @override
  String get helpTipMeetingBody =>
      'If you ever do, tell a parent or a friend, pick a busy public place and bring someone along. Under 18, check with a parent or guardian first.';

  @override
  String get helpTipStopTitle => 'You can always stop';

  @override
  String get helpTipStopBody =>
      'Leave a chat, block or report. You never owe anyone a reply.';

  @override
  String get helpSectionBlockReport => 'Block or report someone';

  @override
  String get helpBlockTitle => 'Block';

  @override
  String get helpBlockBody =>
      'Open their profile or chat, tap the three dots, then Block. They can’t message you or see you.';

  @override
  String get helpReportTitle => 'Report';

  @override
  String get helpReportBody =>
      'From the same menu, tap Report and pick a reason. They never see who reported them.';

  @override
  String get helpYourReportsTitle => 'Your reports';

  @override
  String get helpYourReportsBody => 'See what happened to reports you sent';

  @override
  String get helpSectionUrgent => 'If you need urgent help';

  @override
  String get helpUrgentIntro =>
      'If you or someone else is in danger, contact local emergency services first. Hiyall can’t send help.';

  @override
  String get helpCrisisEmergencyPlace => 'Emergency services';

  @override
  String get helpCrisisEmergencyLine =>
      'Call your local emergency number (911, 999, 112, 000).';

  @override
  String get helpCrisisUSPlace => 'United States';

  @override
  String get helpCrisisUSLine =>
      '988 Suicide & Crisis Lifeline: call or text 988.';

  @override
  String get helpCrisisUKPlace => 'United Kingdom';

  @override
  String get helpCrisisUKLine =>
      'Samaritans: 116 123. Childline (under 19): 0800 1111.';

  @override
  String get helpCrisisCAPlace => 'Canada';

  @override
  String get helpCrisisCALine =>
      'Talk Suicide Canada: 1-833-456-4566. Kids Help Phone: text 686868.';

  @override
  String get helpCrisisAUPlace => 'Australia';

  @override
  String get helpCrisisAULine =>
      'Lifeline: 13 11 14. Kids Helpline: 1800 55 1800.';

  @override
  String get helpCrisisINPlace => 'India';

  @override
  String get helpCrisisINLine => 'Tele-MANAS: 14416.';

  @override
  String get helpCrisisElsePlace => 'Anywhere else';

  @override
  String get helpCrisisElseLine =>
      'Find a helpline for your country at findahelpline.com.';

  @override
  String get helpSectionRules => 'Our rules';
}
