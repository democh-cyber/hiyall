import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// `context.l10n.helpTitle`: the current language's strings.
///
/// Falls back to English when there is no localization scope above (a widget
/// pumped under a bare `MaterialApp` in a test), so screens never crash for
/// the want of one.
extension L10nContext on BuildContext {
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      lookupAppLocalizations(const Locale('en'));
}
