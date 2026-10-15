import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Button at the top of Help & Safety that returns to Settings.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get helpBack;

  /// Title of the Help & Safety screen.
  ///
  /// In en, this message translates to:
  /// **'Help & Safety'**
  String get helpTitle;

  /// No description provided for @helpIntro.
  ///
  /// In en, this message translates to:
  /// **'A real person reads what you send. Tap an address to write to us, or copy it.'**
  String get helpIntro;

  /// Section heading, shown in capitals.
  ///
  /// In en, this message translates to:
  /// **'Contact us'**
  String get helpSectionContact;

  /// No description provided for @helpContactHelp.
  ///
  /// In en, this message translates to:
  /// **'Help and feedback'**
  String get helpContactHelp;

  /// No description provided for @helpContactSafety.
  ///
  /// In en, this message translates to:
  /// **'Safety concerns'**
  String get helpContactSafety;

  /// No description provided for @helpContactPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy and your data'**
  String get helpContactPrivacy;

  /// Shown in place of a contact address that is not set up yet.
  ///
  /// In en, this message translates to:
  /// **'Contact details are being set up'**
  String get helpContactSettingUpTitle;

  /// No description provided for @helpContactSettingUpBody.
  ///
  /// In en, this message translates to:
  /// **'Until they are ready, use Block and Report in the app: open their profile or chat, tap the three dots, and choose Block or Report. We review every report.'**
  String get helpContactSettingUpBody;

  /// Subject of the mail draft for the help address; the app adds the version after it.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get helpMailSubjectHelp;

  /// No description provided for @helpMailSubjectSafety.
  ///
  /// In en, this message translates to:
  /// **'Safety'**
  String get helpMailSubjectSafety;

  /// No description provided for @helpMailSubjectPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get helpMailSubjectPrivacy;

  /// Tooltip of the copy button beside an email address.
  ///
  /// In en, this message translates to:
  /// **'Copy {address}'**
  String helpCopyTooltip(String address);

  /// Message after an address was copied.
  ///
  /// In en, this message translates to:
  /// **'Copied {address}'**
  String helpCopied(String address);

  /// Message when no mail app opened; the address went to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'No mail app here. Copied {address} instead.'**
  String helpNoMailApp(String address);

  /// Section heading, shown in capitals.
  ///
  /// In en, this message translates to:
  /// **'Staying safe'**
  String get helpSectionStayingSafe;

  /// No description provided for @helpTipKeepInHiyallTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep it in Hiyall at first'**
  String get helpTipKeepInHiyallTitle;

  /// No description provided for @helpTipKeepInHiyallBody.
  ///
  /// In en, this message translates to:
  /// **'Don’t share your phone number, address, school or where you hang out with someone you just met.'**
  String get helpTipKeepInHiyallBody;

  /// No description provided for @helpTipPeopleTitle.
  ///
  /// In en, this message translates to:
  /// **'People can pretend'**
  String get helpTipPeopleTitle;

  /// No description provided for @helpTipPeopleBody.
  ///
  /// In en, this message translates to:
  /// **'Someone may not be who they say. If it feels off, trust that feeling.'**
  String get helpTipPeopleBody;

  /// No description provided for @helpTipPhotoTitle.
  ///
  /// In en, this message translates to:
  /// **'Think before you send a photo'**
  String get helpTipPhotoTitle;

  /// No description provided for @helpTipPhotoBody.
  ///
  /// In en, this message translates to:
  /// **'A photo can be saved or shared by the person who gets it, even in an encrypted chat.'**
  String get helpTipPhotoBody;

  /// No description provided for @helpTipMeetingTitle.
  ///
  /// In en, this message translates to:
  /// **'Meeting in person'**
  String get helpTipMeetingTitle;

  /// No description provided for @helpTipMeetingBody.
  ///
  /// In en, this message translates to:
  /// **'If you ever do, tell a parent or a friend, pick a busy public place and bring someone along. Under 18, check with a parent or guardian first.'**
  String get helpTipMeetingBody;

  /// No description provided for @helpTipStopTitle.
  ///
  /// In en, this message translates to:
  /// **'You can always stop'**
  String get helpTipStopTitle;

  /// No description provided for @helpTipStopBody.
  ///
  /// In en, this message translates to:
  /// **'Leave a chat, block or report. You never owe anyone a reply.'**
  String get helpTipStopBody;

  /// Section heading, shown in capitals.
  ///
  /// In en, this message translates to:
  /// **'Block or report someone'**
  String get helpSectionBlockReport;

  /// No description provided for @helpBlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get helpBlockTitle;

  /// No description provided for @helpBlockBody.
  ///
  /// In en, this message translates to:
  /// **'Open their profile or chat, tap the three dots, then Block. They can’t message you or see you.'**
  String get helpBlockBody;

  /// No description provided for @helpReportTitle.
  ///
  /// In en, this message translates to:
  /// **'Report'**
  String get helpReportTitle;

  /// No description provided for @helpReportBody.
  ///
  /// In en, this message translates to:
  /// **'From the same menu, tap Report and pick a reason. They never see who reported them.'**
  String get helpReportBody;

  /// No description provided for @helpYourReportsTitle.
  ///
  /// In en, this message translates to:
  /// **'Your reports'**
  String get helpYourReportsTitle;

  /// No description provided for @helpYourReportsBody.
  ///
  /// In en, this message translates to:
  /// **'See what happened to reports you sent'**
  String get helpYourReportsBody;

  /// Section heading, shown in capitals.
  ///
  /// In en, this message translates to:
  /// **'If you need urgent help'**
  String get helpSectionUrgent;

  /// No description provided for @helpUrgentIntro.
  ///
  /// In en, this message translates to:
  /// **'If you or someone else is in danger, contact local emergency services first. Hiyall can’t send help.'**
  String get helpUrgentIntro;

  /// Where a helpline works: a country, or a general heading.
  ///
  /// In en, this message translates to:
  /// **'Emergency services'**
  String get helpCrisisEmergencyPlace;

  /// Confirm every number for the countries you launch in before release (docs/mobile/store-listing.md).
  ///
  /// In en, this message translates to:
  /// **'Call your local emergency number (911, 999, 112, 000).'**
  String get helpCrisisEmergencyLine;

  /// No description provided for @helpCrisisUSPlace.
  ///
  /// In en, this message translates to:
  /// **'United States'**
  String get helpCrisisUSPlace;

  /// No description provided for @helpCrisisUSLine.
  ///
  /// In en, this message translates to:
  /// **'988 Suicide & Crisis Lifeline: call or text 988.'**
  String get helpCrisisUSLine;

  /// No description provided for @helpCrisisUKPlace.
  ///
  /// In en, this message translates to:
  /// **'United Kingdom'**
  String get helpCrisisUKPlace;

  /// No description provided for @helpCrisisUKLine.
  ///
  /// In en, this message translates to:
  /// **'Samaritans: 116 123. Childline (under 19): 0800 1111.'**
  String get helpCrisisUKLine;

  /// No description provided for @helpCrisisCAPlace.
  ///
  /// In en, this message translates to:
  /// **'Canada'**
  String get helpCrisisCAPlace;

  /// No description provided for @helpCrisisCALine.
  ///
  /// In en, this message translates to:
  /// **'Talk Suicide Canada: 1-833-456-4566. Kids Help Phone: text 686868.'**
  String get helpCrisisCALine;

  /// No description provided for @helpCrisisAUPlace.
  ///
  /// In en, this message translates to:
  /// **'Australia'**
  String get helpCrisisAUPlace;

  /// No description provided for @helpCrisisAULine.
  ///
  /// In en, this message translates to:
  /// **'Lifeline: 13 11 14. Kids Helpline: 1800 55 1800.'**
  String get helpCrisisAULine;

  /// No description provided for @helpCrisisINPlace.
  ///
  /// In en, this message translates to:
  /// **'India'**
  String get helpCrisisINPlace;

  /// No description provided for @helpCrisisINLine.
  ///
  /// In en, this message translates to:
  /// **'Tele-MANAS: 14416.'**
  String get helpCrisisINLine;

  /// No description provided for @helpCrisisElsePlace.
  ///
  /// In en, this message translates to:
  /// **'Anywhere else'**
  String get helpCrisisElsePlace;

  /// No description provided for @helpCrisisElseLine.
  ///
  /// In en, this message translates to:
  /// **'Find a helpline for your country at findahelpline.com.'**
  String get helpCrisisElseLine;

  /// Section heading, shown in capitals.
  ///
  /// In en, this message translates to:
  /// **'Our rules'**
  String get helpSectionRules;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
