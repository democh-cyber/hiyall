import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/avatar_upload.dart';
import '../../core/legal_documents.dart';
import '../../core/profile_labels.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../shared/avatar_sheet.dart';
import '../../shared/person_avatar.dart';
import '../../shared/widgets.dart';
import '../legal_screens.dart' show LegalLink;
import '../nearby_optin.dart' show NearbyExplanation, shareNearby;
import '../../core/location_sync.dart' show locationProblemProvider;
import '../profile_editor.dart' show pickProfileLabel;

const _interestSuggestions = [
  'Music',
  'Technology',
  'Travel',
  'Photography',
  'Movies',
  'Art',
  'Gaming',
  'Reading',
  'Fitness',
  'Food',
  'Nature',
  'Learning',
];
const _vibes = [
  'Chill',
  'Creative',
  'Explorer',
  'Bookish',
  'Night owl',
  'Active',
];
// The languages most people pick; anything else is a search away.
const _popularLanguages = [
  'en',
  'hi',
  'es',
  'fr',
  'ar',
  'pt',
  'bn',
  'ru',
  'ja',
  'de',
  'zh',
  'ta',
  'te',
  'mr',
  'ur',
  'ko',
  'it',
  'id',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
final _usernamePattern = RegExp(r'^[a-z0-9_]{3,30}$');

// Same dedupe the people filters use: one entry per display name.
final _languageChoices = () {
  final entries = languageNames.entries.toList()
    ..sort((a, b) => a.key.length.compareTo(b.key.length));
  final names = <String>{};
  return Map<String, String>.fromEntries(
    entries.where((e) => names.add(e.value)),
  );
}();

/// The youngest age the identity providers' terms and children's-privacy law
/// allow for an account. Mirrors the API's `MinimumAge`.
const minimumAge = 13;

bool meetsMinimumAge(DateTime birth, DateTime today) {
  var age = today.year - birth.year;
  if (today.month < birth.month ||
      (today.month == birth.month && today.day < birth.day)) {
    age--;
  }
  return age >= minimumAge;
}

/// Whether someone born on [birth] is under 18 on [today] (the stricter Nearby wording is for them).
bool isMinorBirth(DateTime birth, DateTime today) {
  var age = today.year - birth.year;
  if (today.month < birth.month ||
      (today.month == birth.month && today.day < birth.day)) {
    age--;
  }
  return age < 18;
}

String isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// A starting username from a name or email: lowercase letters, digits, `_`.
String suggestUsername(String source) {
  var text = source
      .toLowerCase()
      .split('@')
      .first
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
  text = text.replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_|_$'), '');
  if (text.length < 3) return '';
  return text.length > 30 ? text.substring(0, 30) : text;
}

/// The age, profile and interest steps a new account completes before entering
/// the app. Nothing is saved until the last step; the server enforces the
/// result (see `/v1/me/onboarding`). The optional photo stays on this device
/// until onboarding is complete, because media routes open only then.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<OnboardingScreen> {
  static const steps = 6;
  final nameForm = GlobalKey<FormState>();
  final name = TextEditingController(), username = TextEditingController();
  final customInterest = TextEditingController();
  int step = 0;
  DateTime? birth;
  bool agreed = false, busy = false, underage = false, cooldown = false;

  /// The person tapped "Turn on Nearby" on the last step. Nearby needs a finished onboarding, so it is switched
  /// on right after, and nothing about it can stop anyone entering the app.
  bool wantNearby = false;
  String? usernameError, error, checkedUsername, country, vibe, gender;
  final languages = <String>[];
  final interests = <String>[];
  late final avatar = AvatarUploadController(ref.read(imagePickerProvider));

  @override
  void initState() {
    super.initState();
    avatar.addListener(_photoChanged);
    _prefill();
  }

  void _photoChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    name.dispose();
    username.dispose();
    customInterest.dispose();
    avatar.dispose();
    super.dispose();
  }

  Future<void> _prefill() async {
    final provider = ref.read(authGatewayProvider).currentUser;
    String? savedName, savedUsername;
    try {
      final profile = await ref.read(profileProvider.future);
      if (profile.displayName != 'Hiyall member') {
        savedName = profile.displayName;
      }
      if (!profile.username.startsWith('member_')) {
        savedUsername = profile.username;
      }
      if (mounted && profile.interests.isNotEmpty && interests.isEmpty) {
        setState(() => interests.addAll(profile.interests));
      }
    } catch (_) {
      // Prefill is a convenience; the form works without it.
    }
    if (!mounted) return;
    final display = savedName ?? provider?.displayName ?? '';
    if (name.text.isEmpty) name.text = display;
    if (username.text.isEmpty) {
      username.text =
          savedUsername ??
          suggestUsername(
            display.isNotEmpty ? display : (provider?.email ?? ''),
          );
    }
    setState(() {});
  }

  Future<void> pickBirth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      // Neutral: it opens on today in the year list, with no suggested age.
      initialDate: birth ?? now,
      initialDatePickerMode: DatePickerMode.year,
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: 'Your date of birth',
    );
    if (picked != null) setState(() => birth = picked);
  }

  void back() => setState(() {
    error = null;
    if (step > 0) step--;
  });

  Future<void> next() async {
    if (busy) return;
    setState(() => error = null);
    if (step == 1) {
      if (!nameForm.currentState!.validate()) return;
      if (!await _usernameFree()) return;
    }
    if (step == 0 && !await _checkAge()) return;
    setState(() => step++);
  }

  /// The date goes to the server now, which refuses a date under 13 and
  /// remembers it, so choosing another date does not get past the age gate.
  Future<bool> _checkAge() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null || birth == null) return false;
    setState(() => busy = true);
    try {
      await ref.read(apiProvider).checkBirthDate(session, isoDate(birth!));
      return true;
    } on ApiFailure catch (failure) {
      if (mounted) {
        setState(() {
          if (failure.code == 'AGE_REQUIREMENT_NOT_MET') {
            underage = true;
          } else if (failure.code == 'AGE_GATE_COOLDOWN') {
            underage = cooldown = true;
          } else {
            error = failure.message;
          }
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _usernameFree() async {
    final wanted = username.text.trim();
    if (wanted == checkedUsername) return true;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return false;
    setState(() {
      busy = true;
      usernameError = null;
    });
    try {
      final free = await ref
          .read(apiProvider)
          .usernameAvailable(session, wanted);
      if (!mounted) return false;
      if (!free) {
        setState(() => usernameError = 'That username is taken. Try another.');
        return false;
      }
      checkedUsername = wanted;
      return true;
    } on ApiFailure catch (failure) {
      if (mounted) {
        setState(
          () => usernameError = failure.status == 429
              ? 'Slow down a little, then try again.'
              : 'Couldn’t check that username. Try again.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Sends the chosen photo and makes it the profile photo. Runs only once
  /// onboarding is complete, and never throws: a photo that fails must not
  /// stop anyone entering the app. Returns whether it worked.
  Future<bool> _attachPhoto(ApiClient api, Session session) async {
    try {
      final id = await avatar.upload(api, session);
      if (id == null) return false;
      await api.setAvatar(session, await api.profile(session), id);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> submit() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null || birth == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    final api = ref.read(apiProvider);
    // The screen is gone by the time the photo finishes, so hold what the
    // message and the refresh need.
    final messenger = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final profile = await api.profile(session);
      await api.updateProfile(session, profile, {
        'displayName': name.text.trim(),
        'username': username.text.trim(),
        'languages': [
          for (final code in languages) ProfileLanguage(code).toJson(),
        ],
        'interests': interests,
        if (country != null) 'country': country,
        if (vibe != null) 'currentVibe': vibe,
        if (gender != null) 'gender': gender,
      });
      final status = await api.onboarding(session);
      if (!status.completed && status.termsVersion != kTermsVersion) {
        // The service now asks for a revision this build does not show. Accepting
        // it would record terms the person never saw.
        if (mounted) {
          setState(
            () => error = 'The terms have changed since this version of Hiyall was released. Update the app to continue.',
          );
        }
        return;
      }
      if (!status.completed) {
        await api.completeOnboarding(
          session,
          birthDate: isoDate(birth!),
          termsVersion: status.termsVersion,
        );
      }
      final photoFailed =
          avatar.photo != null && !await _attachPhoto(api, session);
      container.invalidate(profileProvider);
      container.read(sessionProvider.notifier).markOnboarded();
      if (wantNearby) unawaited(_turnOnNearby(container, session));
      if (photoFailed) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'We couldn’t upload your photo. You can add it from your profile.',
              ),
            ),
          );
      }
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        if (failure.code == 'AGE_REQUIREMENT_NOT_MET') {
          underage = true;
        } else if (failure.code == 'AGE_GATE_COOLDOWN') {
          underage = cooldown = true;
        } else if (failure.status == 409 ||
            failure.code == 'PROFILE_INCOMPLETE') {
          step = 1;
          checkedUsername = null;
          usernameError = failure.status == 409
              ? 'That username was just taken. Try another.'
              : failure.message;
        } else {
          error = failure.message;
        }
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Switches Nearby on once onboarding is complete, after the person said yes on the last step. The system
  /// permission prompt appears here, and only because they tapped. Never throws: whatever goes wrong (a refused
  /// permission, a dropped connection) leaves Nearby off or without an area, and Discover's Nearby view says so.
  Future<void> _turnOnNearby(
    ProviderContainer container,
    Session session,
  ) async {
    try {
      await shareNearby(
        api: container.read(apiProvider),
        session: session,
        account: container.read(sessionProvider.notifier),
        locator: container.read(locationServiceProvider),
        setProblem: container.read(locationProblemProvider.notifier).set,
      );
    } catch (_) {
      // Not needed for anything but the Nearby tab.
    }
  }

  Future<void> signOut() async {
    try {
      await ref.read(sessionProvider.notifier).logout();
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  bool get canContinue => switch (step) {
    0 => birth != null && agreed,
    1 => true,
    4 => interests.length >= 3,
    _ => true,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (underage) return _Blocked(onSignOut: signOut, cooldown: cooldown);
    final titles = [
      'First, the basics',
      'Make it yours',
      'Add a photo',
      'A bit about you',
      'What you’re into',
      'Find people near you',
    ];
    final subtitles = [
      'Hiyall is for people 13 and over. We use your date of birth to keep younger members safe and to power the age filter. It never appears on your profile.',
      'Your name and username are how people find and recognise you.',
      'Optional. A friendly face helps people recognise you.',
      'Optional. This helps you meet people who share your background.',
      'Pick at least three. They shape who and what you see.',
      'Optional. Nearby lists people close to you. Nothing is shared until you turn it on, and it is never needed to use Hiyall.',
    ];
    final body = switch (step) {
      0 => _ageStep(context),
      1 => _nameStep(context),
      2 => _photoStep(context),
      3 => _whereStep(context),
      4 => _interestsStep(context),
      _ => _nearbyStep(context),
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 16, 0),
                  child: Row(
                    children: [
                      if (step > 0)
                        IconButton(
                          key: const Key('onb-back'),
                          tooltip: 'Back',
                          onPressed: busy ? null : back,
                          icon: const Icon(Icons.arrow_back_rounded),
                        )
                      else
                        const SizedBox(width: 48, height: 48),
                      Expanded(
                        child: Semantics(
                          label: 'Step ${step + 1} of $steps',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(100),
                            child: LinearProgressIndicator(
                              value: (step + 1) / steps,
                              minHeight: 6,
                              backgroundColor: scheme.outlineVariant,
                              color: VibeColors.lime,
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('onb-signout'),
                        onPressed: busy ? null : signOut,
                        child: const Text('Sign out'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'STEP ${step + 1} OF $steps',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.3,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          titles[step],
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          subtitles[step],
                          style: TextStyle(
                            height: 1.6,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 26),
                        body,
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            error!,
                            key: const Key('onb-error'),
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      if (step == steps - 1) ...[
                        FilledButton(
                          key: const Key('onb-nearby-on'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: busy
                              ? null
                              : () {
                                  wantNearby = true;
                                  submit();
                                },
                          child: Text(busy ? 'Setting up…' : 'Turn on Nearby'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          key: const Key('onb-finish'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: busy
                              ? null
                              : () {
                                  wantNearby = false;
                                  submit();
                                },
                          child: const Text('Not now'),
                        ),
                      ] else
                        FilledButton(
                          key: const Key('onb-next'),
                          onPressed: busy || !canContinue ? null : next,
                          child: Text(busy ? 'Checking…' : 'Continue'),
                        ),
                      if (step == 3 || (step == 2 && avatar.photo == null))
                        TextButton(
                          key: const Key('onb-skip'),
                          onPressed: busy ? null : () => setState(() => step++),
                          child: const Text('Skip for now'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "Find people near you": what Nearby shares, with the same words as the explainer sheet, and no pressure.
  Widget _nearbyStep(BuildContext context) => Column(
    key: const Key('onb-nearby-step'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      NearbyExplanation(
        minor: birth != null && isMinorBirth(birth!, DateTime.now()),
        title: false,
      ),
      Text(
        'Choosing “Not now” changes nothing else: you can turn Nearby on later from Discover.',
        style: TextStyle(
          fontSize: 13.5,
          height: 1.4,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _ageStep(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const Key('onb-dob'),
          onPressed: busy ? null : pickBirth,
          icon: const Icon(Icons.cake_outlined),
          label: Text(
            birth == null
                ? 'Choose your date of birth'
                : '${birth!.day} ${_months[birth!.month - 1]} ${birth!.year}',
          ),
        ),
        const SizedBox(height: 20),
        CheckboxListTile(
          key: const Key('onb-terms'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: agreed,
          onChanged: busy ? null : (v) => setState(() => agreed = v ?? false),
          title: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('I agree to the '),
              const LegalLink(LegalDoc.terms, label: 'Terms'),
              const Text(', '),
              const LegalLink(LegalDoc.privacy, label: 'Privacy Policy'),
              const Text(' and '),
              const LegalLink(
                LegalDoc.guidelines,
                label: 'Community Guidelines',
              ),
              const Text('.'),
            ],
          ),
          subtitle: Text(
            'Terms version $kTermsVersion',
            key: const Key('onb-terms-version'),
          ),
        ),
        const Align(
          alignment: AlignmentDirectional.centerStart,
          child: LegalLink(LegalDoc.teens, label: 'Children and Teens'),
        ),
        Text(
          'Your birth date stays private. Nobody can see it, and it can\u2019t be changed later.',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _nameStep(BuildContext context) => Form(
    key: nameForm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('onb-name'),
          controller: name,
          enabled: !busy,
          maxLength: 80,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          autofillHints: const [AutofillHints.name],
          decoration: const InputDecoration(labelText: 'Display name'),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name.' : null,
        ),
        const SizedBox(height: 10),
        TextFormField(
          key: const Key('onb-username'),
          controller: username,
          enabled: !busy,
          maxLength: 30,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() => usernameError = null),
          onFieldSubmitted: (_) => next(),
          decoration: InputDecoration(
            labelText: 'Username',
            prefixText: '@',
            errorText: usernameError,
            helperText: 'Lowercase letters, numbers and underscores.',
          ),
          validator: (v) => _usernamePattern.hasMatch((v ?? '').trim())
              ? null
              : 'Use 3–30 lowercase letters, numbers or underscores.',
        ),
      ],
    ),
  );

  Future<void> _choosePhoto() async {
    final action = await showAvatarSheet(
      context,
      hasPhoto: avatar.photo != null,
    );
    switch (action) {
      case AvatarAction.gallery:
        await avatar.pick(AvatarSource.gallery);
      case AvatarAction.camera:
        await avatar.pick(AvatarSource.camera);
      case AvatarAction.remove:
        avatar.clear();
      case null:
        break;
    }
  }

  Widget _photoStep(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final photo = avatar.photo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Semantics(
            button: true,
            label: photo == null ? 'Choose a photo' : 'Change photo',
            excludeSemantics: true,
            child: InkWell(
              key: const Key('onb-photo'),
              customBorder: const CircleBorder(),
              onTap: busy ? null : _choosePhoto,
              child: PersonAvatar(
                name: name.text,
                bytes: photo?.bytes,
                radius: 80,
                fallback: const ColoredBox(
                  color: VibeColors.lilac,
                  child: Center(
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: 48,
                      color: VibeColors.ink,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.tonalIcon(
          key: const Key('onb-photo-choose'),
          onPressed: busy ? null : _choosePhoto,
          icon: const Icon(Icons.add_a_photo_outlined),
          label: Text(photo == null ? 'Choose a photo' : 'Choose another'),
        ),
        if (photo != null)
          TextButton(
            key: const Key('onb-photo-remove'),
            onPressed: busy ? null : avatar.clear,
            child: const Text('Remove'),
          ),
        if (avatar.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              avatar.error!.message,
              key: const Key('onb-photo-error'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          'Your photo is public, like the rest of your profile.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _whereStep(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Gender', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (value, label) in const [
            ('woman', 'Woman'),
            ('man', 'Man'),
            ('nonbinary', 'Non-binary'),
          ])
            ChoiceChip(
              key: Key('onb-gender-$value'),
              label: Text(label),
              selected: gender == value,
              onSelected: busy
                  ? null
                  : (on) => setState(() => gender = on ? value : null),
            ),
        ],
      ),
      const SizedBox(height: 26),
      Text('Country', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('onb-country'),
        onPressed: busy
            ? null
            : () async {
                final picked = await pickProfileLabel(
                  context,
                  'Choose your country',
                  countryNames,
                  allowClear: country != null,
                );
                if (picked != null) {
                  setState(() => country = picked.isEmpty ? null : picked);
                }
              },
        icon: const Icon(Icons.public_rounded),
        label: Text(
          country == null
              ? 'Choose a country'
              : (countryNames[country] ?? country!),
        ),
      ),
      const SizedBox(height: 26),
      Text(
        'Languages you speak',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final code in {..._popularLanguages, ...languages})
            FilterChip(
              label: Text(languageLabel(code)),
              selected: languages.contains(code),
              onSelected: busy
                  ? null
                  : (on) => setState(() {
                      if (!on) {
                        languages.remove(code);
                      } else if (languages.length < 9) {
                        languages.add(code);
                      }
                    }),
            ),
        ],
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const Key('onb-language'),
        onPressed: busy || languages.length >= 9
            ? null
            : () async {
                final picked = await pickProfileLabel(
                  context,
                  'More languages',
                  {
                    for (final e in _languageChoices.entries)
                      if (!languages.contains(e.key)) e.key: e.value,
                  },
                );
                if (picked != null && picked.isNotEmpty) {
                  setState(() => languages.add(picked));
                }
              },
        icon: const Icon(Icons.add_rounded),
        label: const Text('More languages'),
      ),
    ],
  );

  void _addInterest(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return;
    if (value.length > 40) {
      return setState(() => error = 'Keep each interest to 40 characters.');
    }
    if (interests.any((v) => v.toLowerCase() == value.toLowerCase())) return;
    if (interests.length >= 10) {
      return setState(() => error = 'Choose up to ten interests.');
    }
    setState(() {
      error = null;
      interests.add(value);
      customInterest.clear();
    });
  }

  Widget _interestsStep(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in {..._interestSuggestions, ...interests})
            FilterChip(
              label: Text(item),
              selected: interests.any(
                (v) => v.toLowerCase() == item.toLowerCase(),
              ),
              onSelected: busy
                  ? null
                  : (on) => setState(() {
                      error = null;
                      if (on) {
                        _addInterest(item);
                      } else {
                        interests.removeWhere(
                          (v) => v.toLowerCase() == item.toLowerCase(),
                        );
                      }
                    }),
            ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        key: const Key('onb-interest'),
        controller: customInterest,
        enabled: !busy,
        maxLength: 40,
        textInputAction: TextInputAction.done,
        onSubmitted: _addInterest,
        decoration: InputDecoration(
          labelText: 'Add your own',
          suffixIcon: IconButton(
            tooltip: 'Add interest',
            onPressed: busy ? null : () => _addInterest(customInterest.text),
            icon: const Icon(Icons.add_rounded),
          ),
        ),
      ),
      Text(
        '${interests.length} of 10 chosen${interests.length < 3 ? ' · pick ${3 - interests.length} more' : ''}',
        style: TextStyle(
          fontSize: 12.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 26),
      Text(
        'Your vibe right now',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in _vibes)
            ChoiceChip(
              label: Text(item),
              selected: vibe == item,
              onSelected: busy
                  ? null
                  : (on) => setState(() => vibe = on ? item : null),
            ),
        ],
      ),
    ],
  );
}

class AuthNoticeBox extends StatelessWidget {
  final String text;
  const AuthNoticeBox(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: VibeColors.peach,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(
      text,
      style: const TextStyle(color: VibeColors.ink, height: 1.5),
    ),
  );
}

/// The account is under the minimum age. There is nothing more to do here.
class _Blocked extends StatelessWidget {
  final VoidCallback onSignOut;

  /// The same sign-in already declared an age under 13 within the last week.
  final bool cooldown;
  const _Blocked({required this.onSignOut, this.cooldown = false});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: BrandMark(size: 56)),
                const SizedBox(height: 24),
                Text(
                  'Hiyall is for people 13 and over',
                  key: const Key('onb-underage'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  cooldown
                      ? 'We can’t finish setting up your account right now. Please try again in a few days. Thanks for understanding.'
                      : 'We can’t create your account right now. Thanks for understanding.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    height: 1.6,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: onSignOut,
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
