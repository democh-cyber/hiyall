import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/avatar_upload.dart';
import '../core/profile_limits.dart';
import '../core/personality.dart' show maxPersonalityTags;
import '../core/state.dart';
import '../core/user_error.dart';
import '../shared/widgets.dart';
import 'profile_editor/profile_avatar_controller.dart';
import 'profile_editor/profile_avatar_editor.dart';
import 'profile_editor/profile_editor_actions.dart';
import 'profile_editor/profile_form_fields.dart';
import 'profile_editor/profile_identity_section.dart';
import 'profile_editor/profile_interests_section.dart';
import 'profile_editor/audience_picker.dart';
import 'profile_editor/profile_languages_section.dart';
import 'profile_editor/profile_personality_section.dart';
import 'profile_editor/profile_photos_controller.dart';
import 'profile_editor/profile_photos_section.dart';
import 'profile_editor/profile_save_bar.dart';
import 'profile_editor/profile_text_section.dart';
import 'nearby_setting.dart' show nearbyStatusProvider;
import 'profile_editor/profile_vibe_section.dart';

export 'profile_editor/profile_label_picker.dart' show pickProfileLabel;

class ProfileForm extends ConsumerStatefulWidget {
  final Profile profile;

  /// Asked to load the newest profile and start the form over, after another
  /// device changed it. Without one, the profile is just reloaded.
  final VoidCallback? onReload;
  const ProfileForm({super.key, required this.profile, this.onReload});
  @override
  ConsumerState<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<ProfileForm> {
  final form = GlobalKey<FormState>();
  late final fields = ProfileFormFields(widget.profile);
  bool busy = false, conflict = false;
  String? error;
  late final avatar = ProfileAvatarController(
    ref.read(profileEditorActionsProvider),
    ref.read(imagePickerProvider),
    widget.profile,
    onMessage: (message) {
      if (mounted) showMessage(context, message);
    },
  );

  late final photos = ProfilePhotosController(
    ref.read(profileEditorActionsProvider),
    ref.read(imagePickerProvider),
    onProfilePhotoChanged: () {
      // The first photo is the profile photo: the profile (and its version) moved on.
      ref.read(profileEditorActionsProvider).invalidateProfile();
    },
  );

  @override
  void initState() {
    super.initState();
    avatar.addListener(_avatarChanged);
    photos.addListener(_avatarChanged);
    photos.load();
  }

  void _avatarChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ProfileForm old) {
    super.didUpdateWidget(old);
    avatar.adopt(widget.profile);
  }

  @override
  void dispose() {
    photos.dispose();
    avatar.dispose();
    fields.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final actions = ref.read(profileEditorActionsProvider);
      await actions.saveProfile(avatar.current, fields.patch());
      actions.invalidateProfile();
      // The audiences are privacy settings: saved after the profile, only those the person changed.
      await actions.saveAudiences(fields.audienceChanges);
      if (mounted) {
        showMessage(context, 'Profile saved.');
        context.go('/profile');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = friendlyError(e);
          conflict = e is ApiFailure && e.status == 412;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void addInterest(String value) {
    value = value.trim();
    if (value.isEmpty) return;
    final interests = fields.interests;
    if (interests.any((item) => item.toLowerCase() == value.toLowerCase())) {
      return;
    }
    if (interests.length >= maxProfileInterests) {
      showMessage(context, 'Choose up to $maxProfileInterests interests.');
      return;
    }
    if (value.runes.length > 40) {
      showMessage(context, 'Keep each interest to 40 characters.');
      return;
    }
    setState(() {
      interests.add(value);
      fields.interest.clear();
    });
  }

  String audienceOf(String field, Map<String, dynamic>? saved, bool minor) =>
      fields.audienceChanges[field] ??
      (saved?[field] as String?) ??
      defaultFieldAudience(field, minor: minor);

  @override
  Widget build(BuildContext context) {
    final saved =
        ref.watch(privacyProvider).asData?.value.values['fieldAudiences']
            as Map<String, dynamic>?;
    final minor = ref.watch(nearbyStatusProvider).asData?.value.minor ?? false;
    final waiting = personalityWaiting(fields.personalityTags.length);
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(24),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: busy ? null : () => context.go('/profile'),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Profile'),
          ),
        ),
        const PageHeader(
          eyebrow: 'Make it yours',
          title: 'A little more you.',
          subtitle: 'Your personality, in your own words.',
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ProfileAvatarEditor(controller: avatar, busy: busy),
        ),
        ProfilePhotosSection(controller: photos, busy: busy || avatar.working),
        Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProfileIdentitySection(
                name: fields.name,
                username: fields.username,
                headline: fields.headline,
                bio: fields.bio,
                quote: fields.quote,
                enabled: !busy,
              ),
              ProfileAboutSection(
                profession: fields.profession,
                pronouns: fields.pronouns,
                gender: fields.gender,
                country: fields.country,
                enabled: !busy,
                onGender: (v) => setState(() => fields.gender = v),
                onCountry: (v) => setState(() => fields.country = v),
              ),
              ProfileLanguagesSection(
                languages: fields.languages,
                enabled: !busy,
                onAdd: (language) =>
                    setState(() => fields.languages.add(language)),
                onRemove: (i) => setState(() => fields.languages.removeAt(i)),
                onLevel: (i, level) => setState(
                  () => fields.languages[i] = fields.languages[i].withLevel(
                    level,
                  ),
                ),
              ),
              ProfilePersonalitySection(
                selected: fields.personalityTags,
                enabled: !busy,
                onToggle: (id, on) => setState(() {
                  if (on) {
                    if (fields.personalityTags.length < maxPersonalityTags) {
                      fields.personalityTags.add(id);
                    }
                  } else {
                    fields.personalityTags.remove(id);
                  }
                }),
              ),
              ProfileInterestsSection(
                interests: fields.interests,
                controller: fields.interest,
                enabled: !busy,
                onAdd: addInterest,
                onRemove: (item) =>
                    setState(() => fields.interests.remove(item)),
              ),
              ProfileTextSection(
                aboutMe: fields.aboutMe,
                hometown: fields.hometown,
                minor: minor,
                enabled: !busy,
                aboutMeAudience: audienceOf('aboutMe', saved, minor),
                hometownAudience: audienceOf('hometown', saved, minor),
                onAudience: (field, value) =>
                    setState(() => fields.audienceChanges[field] = value),
              ),
              ProfileVibeSection(
                controller: fields.vibe,
                enabled: !busy,
                onPick: (item) => setState(() => fields.vibe.text = item),
                onClear: () => setState(() => fields.vibe.clear()),
              ),
              ProfileSignatureSection(
                accent: fields.accent,
                pattern: fields.pattern,
                frame: fields.frame,
                enabled: !busy,
                onAccent: (v) => setState(() => fields.accent = v),
                onPattern: (v) => setState(() => fields.pattern = v),
                onFrame: (v) => setState(() => fields.frame = v),
              ),
              ProfileSaveBar(
                error: error,
                conflict: conflict,
                busy: busy,
                canSave:
                    !(busy ||
                        conflict ||
                        avatar.working ||
                        photos.busy ||
                        waiting != null),
                waiting: waiting,
                onReload:
                    widget.onReload ?? () => ref.invalidate(profileProvider),
                onSave: save,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
