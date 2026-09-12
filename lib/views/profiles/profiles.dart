import 'package:fl_clash/services/profile_order.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/scan.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/theme/typography/type_scale.dart';
import 'package:fl_clash/views/profiles/overwrite/overwrite.dart';
import 'package:fl_clash/views/proxies/common.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'edit.dart';
import 'media_check.dart';
import 'preview.dart';

class ProfilesView extends StatefulWidget {
  const ProfilesView({super.key});

  @override
  State<ProfilesView> createState() => _ProfilesViewState();
}

class _ProfilesViewState extends State<ProfilesView> {
  Function? applyConfigDebounce;
  bool _isUpdating = false;
  bool _isCurrentExpanded = false;

  // final GlobalKey _targetKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // WidgetsBinding.instance.addPostFrameCallback((_) {
    //   final context = _targetKey.currentContext;
    //   if (context == null) {
    //     return;
    //   }
    //   Scrollable.ensureVisible(
    //     context,
    //     duration: commonDuration,
    //     alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    //   );
    // });
  }

  Future<void> _updateProfiles(List<Profile> profiles) async {
    if (_isUpdating == true) {
      return;
    }
    _isUpdating = true;
    final List<UpdatingMessage> messages = [];
    final updateProfiles = profiles.map<Future>((profile) async {
      if (profile.type == ProfileType.file) return;
      try {
        await globalState.container
            .read(profilesActionProvider.notifier)
            .updateProfile(profile, showLoading: true, publishInput: false);
      } catch (e) {
        messages.add(
          UpdatingMessage(label: profile.realLabel, message: e.toString()),
        );
      }
    });
    await Future.wait(updateProfiles);
    if (messages.isNotEmpty) {
      globalState.showAllUpdatingMessagesDialog(messages);
    }
    _isUpdating = false;
  }

  List<SlAppBarAction> _buildActions(List<Profile> profiles) {
    return [
      SlAppBarOverflowAction(
        tooltip: context.appLocalizations.more,
        popup: CommonPopupMenu(
          items: [
            if (profiles.isNotEmpty)
              PopupMenuItemData(
                icon: SurgeIcons.sync,
                label: context.appLocalizations.sync,
                onPressed: () {
                  _updateProfiles(profiles);
                },
              ),
            PopupMenuItemData(
              icon: SurgeIcons.tune,
              label: context.appLocalizations.settings,
              onPressed: () {
                showSheet(
                  context: context,
                  props: const SheetProps(isScrollControlled: true),
                  builder: (_) {
                    return AdaptiveSheetScaffold(
                      body: _ProfilesManageSheet(profiles: profiles),
                      title: context.appLocalizations.profileManagement,
                      appBarActions: const [],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (_, ref, _) {
        final appLocalizations = context.appLocalizations;
        final surge = SurgeTheme.of(context);
        final isLoading = ref.watch(loadingProvider(LoadingTag.profiles));
        final state = ref.watch(profilesStateProvider);
        final currentProfile = state.profiles.getProfile(
          state.currentProfileId,
        );
        return CommonScaffold(
          backgroundColor: surge.background,
          isLoading: isLoading,
          title: context.appLocalizations.profiles,
          appBarActions: _buildActions(state.profiles),
          titleVariant: SlAppBarTitleVariant.root,
          body: state.profiles.isEmpty
              ? NullStatus(
                  label: appLocalizations.nullProfileDesc,
                  illustration: const ProfileEmptyIllustration(),
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: SingleChildScrollView(
                    key: profilesStoreKey,
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 12,
                      bottom: SurgeBottomNavLayout.mainPageBottomPadding(
                        context,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (currentProfile != null)
                          _CurrentProfileSummary(
                            profile: currentProfile,
                            profiles: state.profiles,
                            expanded: _isCurrentExpanded,
                            onExpandChanged: () {
                              setState(() {
                                _isCurrentExpanded = !_isCurrentExpanded;
                              });
                            },
                          ),
                        const SizedBox(height: 14),
                        SurgeSection(
                          title: context.appLocalizations.subscriptions,
                          margin: const EdgeInsets.only(bottom: 14),
                          children: [
                            _ProfileListContainer(
                              profiles: state.profiles,
                              currentProfileId: state.currentProfileId,
                              onSelect: (profileId) {
                                if (profileId == null ||
                                    profileId == state.currentProfileId) {
                                  return;
                                }
                                ref.read(providersProvider.notifier).clear();
                                ref.read(groupsProvider.notifier).value =
                                    const [];
                                ref
                                    .read(groupsOwnerProfileIdProvider.notifier)
                                    .set(null);
                                ref
                                    .read(proxiesActionProvider.notifier)
                                    .beginRuntimeProfileTransition(profileId);
                                ref
                                        .read(currentProfileIdProvider.notifier)
                                        .value =
                                    profileId;
                                unawaited(() async {
                                  await ref
                                      .read(proxiesActionProvider.notifier)
                                      .hydrateProxyGroupsSnapshot();
                                  await ref
                                      .read(proxiesActionProvider.notifier)
                                      .ensureCurrentProfileReady(
                                        forceApply: true,
                                      );
                                }());
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _MediaCheckCompactRow extends StatelessWidget {
  const _MediaCheckCompactRow({required this.profile, required this.profiles});

  final Profile profile;
  final List<Profile> profiles;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final profileCount = profiles.length;
    return SurgePressable(
      behavior: HitTestBehavior.opaque,
      scaleFeedback: false,
      overlayInsets: EdgeInsets.symmetric(vertical: surge.spacing.hairline),
      overlayBaseColor: surge.card,
      onTap: () {
        BaseNavigator.push(
          context,
          ProfileMediaCheckView(profiles: profiles, initialProfile: profile),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _SoftOsIconSurface(
              icon: SurgeIcons.mediaCheck,
              color: surge.primary,
              size: 30,
              radius: 10,
              iconSize: 15,
              backgroundAlpha: 0.08,
              foregroundAlpha: 0.88,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.appLocalizations.mediaCheck,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typography.itemLabel.copyWith(
                      color: surge.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profileCount > 1
                        ? context.appLocalizations.mediaCheckByProfileDesc
                        : context.appLocalizations.mediaCheckDesc,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typography.compactDescription.copyWith(
                      color: surge.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const SoftOsIconButton(
              icon: SurgeIcons.chevronRight,
              onPressed: null,
              visualSize: 30,
              tapSize: 44,
              iconSize: 15,
            ),
          ],
        ),
      ),
    );
  }
}

class _SoftOsIconSurface extends StatelessWidget {
  const _SoftOsIconSurface({
    required this.icon,
    required this.color,
    this.size = 30,
    this.radius,
    this.iconSize = 16,
    this.backgroundAlpha = 0.055,
    this.foregroundAlpha = 0.72,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double? radius;
  final double iconSize;
  final double backgroundAlpha;
  final double foregroundAlpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: backgroundAlpha),
        borderRadius: BorderRadius.circular(radius ?? size / 2),
      ),
      child: Icon(
        icon,
        size: iconSize,
        color: color.withValues(alpha: foregroundAlpha),
      ),
    );
  }
}

class _ProfilesManageSheet extends StatefulWidget {
  const _ProfilesManageSheet({required this.profiles});

  final List<Profile> profiles;

  @override
  State<_ProfilesManageSheet> createState() => _ProfilesManageSheetState();
}

class _ProfilesManageSheetState extends State<_ProfilesManageSheet> {
  late List<Profile> _profiles;

  @override
  void initState() {
    super.initState();
    _profiles = List.from(widget.profiles);
  }

  @override
  void didUpdateWidget(covariant _ProfilesManageSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!profileListEquality.equals(oldWidget.profiles, widget.profiles)) {
      _profiles = List.from(widget.profiles);
    }
  }

  Future<void> _handleAddProfileFormFile() async {
    await globalState.container
        .read(profilesActionProvider.notifier)
        .addProfileFormFile();
  }

  Future<void> _handleAddProfileFormURL(
    String url, {
    String? label,
    bool autoUpdate = true,
    Duration autoUpdateDuration = defaultUpdateDuration,
  }) async {
    await globalState.container
        .read(profilesActionProvider.notifier)
        .addProfileFormURL(
          url,
          label: label,
          autoUpdate: autoUpdate,
          autoUpdateDuration: autoUpdateDuration,
        );
  }

  Future<void> _toScan() async {
    if (system.isDesktop) {
      await globalState.container
          .read(profilesActionProvider.notifier)
          .addProfileFormQrCode();
      return;
    }
    final url = await BaseNavigator.push(context, const ScanPage());
    if (url != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleAddProfileFormURL(url);
      });
    }
  }

  Future<void> _toAddUrl() async {
    final result = await showSheet<_AddUrlProfileResult>(
      context: context,
      props: const SheetProps(isScrollControlled: true),
      builder: (_) {
        return const FractionallySizedBox(
          heightFactor: 0.75,
          child: _AddUrlProfileSheet(),
        );
      },
    );
    if (result != null) {
      await _handleAddProfileFormURL(
        result.url,
        label: result.label,
        autoUpdate: result.autoUpdate,
        autoUpdateDuration: result.autoUpdateDuration,
      );
    }
  }

  void _handleReorder(int oldIndex, int newIndex) {
    setState(() {
      reorderProfileList(_profiles, oldIndex, newIndex);
    });
    globalState.container.read(profilesProvider.notifier).reorder(_profiles);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ProfileSettingSection(
            title: context.appLocalizations.addProfileTitle,
            children: [
              _ProfileSettingOption(
                label: appLocalizations.qrcode,
                subtitle: appLocalizations.qrcodeDesc,
                onTap: _toScan,
              ),
              _ProfileSettingOption(
                label: appLocalizations.file,
                subtitle: appLocalizations.fileDesc,
                onTap: _handleAddProfileFormFile,
              ),
              _ProfileSettingOption(
                label: appLocalizations.url,
                subtitle: appLocalizations.urlDesc,
                onTap: _toAddUrl,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ProfileSettingSection(
            title: context.appLocalizations.profileSort,
            subtitle: '${_profiles.length}',
            children: [
              if (_profiles.isEmpty)
                _ProfileSettingOption(
                  icon: SurgeIcons.sort,
                  label: context.appLocalizations.noProfiles,
                  enabled: false,
                  onTap: () {},
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  proxyDecorator: (child, index, animation) {
                    return commonProxyDecorator(child, index, animation);
                  },
                  onReorder: _handleReorder,
                  itemBuilder: (_, index) {
                    final profile = _profiles[index];
                    return _ProfileSortOption(
                      key: ValueKey(profile.id),
                      profile: profile,
                      index: index,
                    );
                  },
                  itemCount: _profiles.length,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddUrlProfileResult {
  const _AddUrlProfileResult({
    required this.url,
    required this.autoUpdate,
    required this.autoUpdateDuration,
    this.label,
  });

  final String url;
  final String? label;
  final bool autoUpdate;
  final Duration autoUpdateDuration;
}

class _AddUrlProfileSheet extends StatefulWidget {
  const _AddUrlProfileSheet();

  @override
  State<_AddUrlProfileSheet> createState() => _AddUrlProfileSheetState();
}

class _AddUrlProfileSheetState extends State<_AddUrlProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _urlController = TextEditingController();
  final _autoUpdateDurationController = TextEditingController(
    text: defaultUpdateDuration.inMinutes.toString(),
  );
  bool _autoUpdate = false;

  void _handleSubmit() {
    if (_formKey.currentState?.validate() == false) return;
    Navigator.of(context).pop(
      _AddUrlProfileResult(
        url: _urlController.text.trim(),
        label: _labelController.text.trim(),
        autoUpdate: _autoUpdate,
        autoUpdateDuration: Duration(
          minutes: int.parse(_autoUpdateDurationController.text),
        ),
      ),
    );
  }

  void _setAutoUpdate(bool value) {
    if (_autoUpdate == value) return;
    setState(() {
      _autoUpdate = value;
    });
  }

  @override
  void dispose() {
    _labelController.dispose();
    _urlController.dispose();
    _autoUpdateDurationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return AdaptiveSheetScaffold(
      title: appLocalizations.importFromURL,
      appBarActions: [
        SlAppBarIconAction(
          icon: SurgeIcons.confirm,
          tooltip: appLocalizations.confirm,
          onPressed: _handleSubmit,
        ),
      ],
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUnfocus,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            20 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            SurgeField(
              label: appLocalizations.name,
              child: TextFormField(
                textInputAction: TextInputAction.next,
                controller: _labelController,
                decoration: surgeInputDecoration(
                  context,
                  hintText: appLocalizations.optional,
                ),
              ),
            ),
            const SizedBox(height: 14),
            SurgeField(
              label: appLocalizations.url,
              child: TextFormField(
                textInputAction: TextInputAction.done,
                keyboardType: TextInputType.url,
                controller: _urlController,
                decoration: surgeInputDecoration(
                  context,
                  hintText: appLocalizations.url,
                ),
                onFieldSubmitted: (_) {
                  _handleSubmit();
                },
                validator: (value) {
                  final url = value?.trim();
                  if (url == null || url.isEmpty) {
                    return appLocalizations.emptyTip('').trim();
                  }
                  if (!url.isUrl) {
                    return appLocalizations.urlTip('').trim();
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(height: 18),
            SurgeToggleFieldRow(
              label: appLocalizations.autoUpdate,
              value: _autoUpdate,
              onChanged: _setAutoUpdate,
            ),
            SurgeAnimatedReveal(
              visible: _autoUpdate,
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SurgeField(
                  label: appLocalizations.autoUpdateInterval,
                  child: TextFormField(
                    textInputAction: TextInputAction.done,
                    keyboardType: TextInputType.number,
                    controller: _autoUpdateDurationController,
                    decoration: surgeInputDecoration(
                      context,
                      hintText: appLocalizations.autoUpdateInterval,
                    ),
                    onFieldSubmitted: (_) {
                      _handleSubmit();
                    },
                    validator: (value) {
                      if (!_autoUpdate) return null;
                      if (value == null || value.isEmpty) {
                        return appLocalizations
                            .profileAutoUpdateIntervalNullValidationDesc;
                      }
                      try {
                        int.parse(value);
                      } catch (_) {
                        return appLocalizations
                            .profileAutoUpdateIntervalInvalidValidationDesc;
                      }
                      return null;
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileSettingSection extends StatelessWidget {
  const _ProfileSettingSection({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Text(
                title,
                style: context.typography.cardTitle.copyWith(
                  color: surge.textPrimary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Text(
                  subtitle!,
                  style: context.typography.chartLabel.copyWith(
                    color: surge.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        SurgeCard(
          padding: EdgeInsets.zero,
          borderRadius: 18,
          shadow: true,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _ProfileSettingOption extends StatelessWidget {
  const _ProfileSettingOption({
    required this.label,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.enabled = true,
  });

  final IconData? icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final foreground = enabled
        ? surge.textSecondary
        : surge.textSecondary.withValues(alpha: 0.4);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: foreground.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(surge.radii.input),
                  ),
                  child: Icon(icon, size: 17, color: foreground),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typography.rowTitle.copyWith(
                        color: enabled
                            ? surge.textPrimary
                            : surge.textSecondary.withValues(alpha: 0.4),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typography.supporting.copyWith(
                          color: surge.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (enabled)
                Icon(
                  SurgeIcons.chevronRight,
                  color: surge.textSecondary.withValues(alpha: 0.75),
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileSortOption extends StatelessWidget {
  const _ProfileSortOption({
    super.key,
    required this.profile,
    required this.index,
  });

  final Profile profile;
  final int index;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                profile.realLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typography.rowTitle.copyWith(
                  color: surge.textPrimary,
                ),
              ),
            ),
            ReorderableDragStartListener(
              index: index,
              child: Icon(
                SurgeIcons.dragHandle,
                color: surge.textSecondary.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentProfileSummary extends StatefulWidget {
  const _CurrentProfileSummary({
    required this.profile,
    required this.profiles,
    required this.expanded,
    required this.onExpandChanged,
  });

  final Profile profile;
  final List<Profile> profiles;
  final bool expanded;
  final VoidCallback onExpandChanged;

  @override
  State<_CurrentProfileSummary> createState() => _CurrentProfileSummaryState();
}

class _CurrentProfileSummaryState extends State<_CurrentProfileSummary> {
  Future<List<Proxy>>? _proxiesFuture;
  void Function()? _removeGroupsListener;

  void _refreshProxies() {
    if (mounted && _proxiesFuture != null) {
      setState(() {
        _proxiesFuture = _loadProfileProxies();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.expanded) {
      _proxiesFuture = _loadProfileProxies();
    }
    final sub = globalState.container.listen(
      groupsProvider,
      (_, _) => _refreshProxies(),
    );
    _removeGroupsListener = sub.close;
  }

  @override
  void dispose() {
    _removeGroupsListener?.call();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CurrentProfileSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id) {
      _proxiesFuture = widget.expanded ? _loadProfileProxies() : null;
      return;
    }
    if (!oldWidget.expanded && widget.expanded && _proxiesFuture == null) {
      _proxiesFuture = _loadProfileProxies();
    }
  }

  Future<List<Proxy>> _loadProfileProxies() async {
    final currentProfileId = globalState.container.read(
      currentProfileIdProvider,
    );
    final groups = globalState.container.read(groupsProvider);
    return loadProfileLeafProxies(
      profileId: widget.profile.id,
      currentProfileId: currentProfileId,
      fallbackGroups: groups,
    );
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final proxiesFuture = _proxiesFuture;
    return FutureBuilder<List<Proxy>>(
      future: proxiesFuture,
      builder: (_, snapshot) {
        final proxies = snapshot.data ?? const <Proxy>[];
        final isLoading =
            widget.expanded &&
            proxiesFuture != null &&
            snapshot.connectionState != ConnectionState.done;
        return SurgeCard(
          shadow: true,
          padding: const EdgeInsets.only(top: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.profile.realLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.typography.featuredTitle.copyWith(
                              color: surge.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _CurrentProfileStatusPill(profileId: widget.profile.id),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _CurrentProfileDetails(profile: widget.profile),
                    const SizedBox(height: 10),
                    Divider(
                      height: 1,
                      thickness: surge.spacing.hairline,
                      color: surge.separator.withValues(alpha: 0.62),
                    ),
                  ],
                ),
              ),
              _MediaCheckCompactRow(
                profile: widget.profile,
                profiles: widget.profiles,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Divider(
                  height: 1,
                  thickness: surge.spacing.hairline,
                  color: surge.separator.withValues(alpha: 0.62),
                ),
              ),
              _CurrentProfileExpandButton(
                expanded: widget.expanded,
                enabled: !isLoading,
                onTap: widget.onExpandChanged,
              ),
              SurgeAnimatedReveal(
                visible: widget.expanded && !isLoading,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: _CurrentProfileProxyPreview(proxies: proxies),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CurrentProfileDetails extends StatelessWidget {
  const _CurrentProfileDetails({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final infoStyle = context.typography.detailLabel.copyWith(
      color: surge.textSecondary,
    );

    return Row(
      children: [
        Icon(
          SurgeIcons.schedule,
          size: 14,
          color: surge.textSecondary.withValues(alpha: 0.82),
        ),
        const SizedBox(width: 6),
        LastUpdateTimeText(
          lastUpdateDate: profile.lastUpdateDate,
          style: infoStyle,
        ),
      ],
    );
  }
}

class _CurrentProfileStatusPill extends ConsumerWidget {
  const _CurrentProfileStatusPill({required this.profileId});

  final int profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surge = SurgeTheme.of(context);
    final snapshot = ref.watch(proxyGroupsSnapshotProvider);
    final groupsOwnerProfileId = ref.watch(groupsOwnerProfileIdProvider);
    final groups = ref.watch(groupsProvider);
    final hasCurrentGroups =
        groupsOwnerProfileId == profileId && groups.isNotEmpty;

    late final String label;
    late final Color color;
    late final bool loading;

    if (hasCurrentGroups ||
        (snapshot.hydrated &&
            groupsOwnerProfileId == profileId &&
            (snapshot.freshness == ProxyGroupsFreshnessState.fresh ||
                snapshot.freshness == ProxyGroupsFreshnessState.stale))) {
      label = context.appLocalizations.currentlyUsed;
      color = surge.semantic.state.profileActive;
      loading = false;
    } else if (snapshot.freshness == ProxyGroupsFreshnessState.refreshing ||
        (groupsOwnerProfileId != null && groupsOwnerProfileId != profileId)) {
      label = context.appLocalizations.switching;
      color = surge.primary;
      loading = true;
    } else if (snapshot.freshness == ProxyGroupsFreshnessState.failed) {
      label = context.appLocalizations.unavailable;
      color = surge.red;
      loading = false;
    } else {
      label = context.appLocalizations.notReady;
      color = surge.textSecondary;
      loading = false;
    }

    return SoftOsStatusPill(
      accentColor: color,
      loading: loading,
      semanticLabel: label,
      minWidth: 76,
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      surfaceAlpha: loading ? 0.11 : 0.17,
      borderAlpha: loading ? 0.20 : 0.31,
      duration: SurgeMotion.reveal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loading) ...[
            SizedBox.square(
              dimension: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: color.withValues(alpha: 0.86),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.typography.pillLabel.copyWith(
              color: color.withValues(alpha: 0.96),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentProfileExpandButton extends StatelessWidget {
  const _CurrentProfileExpandButton({
    required this.expanded,
    required this.enabled,
    required this.onTap,
  });

  final bool expanded;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Semantics(
      button: true,
      enabled: enabled,
      child: SurgePressable(
        enabled: enabled,
        compact: true,
        behavior: HitTestBehavior.opaque,
        scaleFeedback: false,
        overlayInsets: EdgeInsets.only(top: surge.spacing.hairline),
        overlayBaseColor: surge.card,
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _SoftOsIconSurface(
                  icon: SurgeIcons.hub,
                  color: enabled ? surge.primary : surge.textSecondary,
                  size: 30,
                  radius: 15,
                  iconSize: 15,
                  backgroundAlpha: enabled ? 0.08 : 0.04,
                  foregroundAlpha: enabled ? 0.88 : 0.55,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    enabled
                        ? context.appLocalizations.expandCurrentProfileNodes
                        : context.appLocalizations.readingCurrentProfileNodes,
                    style: context.typography.itemLabel.copyWith(
                      color: enabled ? surge.textPrimary : surge.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IgnorePointer(
                  child: AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: SurgeMotion.reveal,
                    child: SoftOsIconButton(
                      icon: SurgeIcons.expand,
                      onPressed: enabled ? onTap : null,
                      visualSize: 30,
                      tapSize: 44,
                      iconSize: 15,
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

class _CurrentProfileProxyPreview extends StatelessWidget {
  const _CurrentProfileProxyPreview({required this.proxies});

  final List<Proxy> proxies;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    if (proxies.isEmpty) {
      return Text(
        context.appLocalizations.currentProfileHasNoNodes,
        style: context.typography.supporting.copyWith(
          color: surge.textSecondary,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, right: 2, bottom: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.appLocalizations.nodeList,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typography.previewLabel.copyWith(
                      color: surge.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${proxies.length}',
                  style: context.typography.countLabel.copyWith(
                    color: surge.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                _ProfileProxyTestAllButton(proxies: proxies),
              ],
            ),
          ),
          SizedBox(
            height: math.min(300, proxies.length * 53).toDouble(),
            child: Theme(
              data: Theme.of(context).copyWith(
                scrollbarTheme: const ScrollbarThemeData(
                  mainAxisMargin: 8,
                  crossAxisMargin: -3,
                ),
              ),
              child: Scrollbar(
                thumbVisibility: false,
                child: ListView.separated(
                  padding: const EdgeInsets.only(right: 3),
                  itemCount: proxies.length,
                  itemBuilder: (_, index) =>
                      _ProfileProxyPreviewCard(proxy: proxies[index]),
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: surge.separator),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileProxyTestAllButton extends StatefulWidget {
  const _ProfileProxyTestAllButton({required this.proxies});

  final List<Proxy> proxies;

  @override
  State<_ProfileProxyTestAllButton> createState() =>
      _ProfileProxyTestAllButtonState();
}

class _ProfileProxyTestAllButtonState
    extends State<_ProfileProxyTestAllButton> {
  var _testing = false;

  Future<void> _handleTestAll() async {
    if (_testing) return;
    setState(() {
      _testing = true;
    });
    await delayTest(widget.proxies);
    if (!mounted) return;
    setState(() {
      _testing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Tooltip(
      message: context.appLocalizations.testAllLatencies,
      child: SurgePressable(
        compact: true,
        borderRadius: BorderRadius.circular(
          SurgeTheme.of(context).radii.compact,
        ),
        onTap: _handleTestAll,
        child: Container(
          width: 28,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: surge.textSecondary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(surge.radii.menuRow),
            border: Border.all(
              color: surge.separator.withValues(alpha: 0.55),
              width: 0.5,
            ),
          ),
          child: AnimatedSwitcher(
            duration: SurgeMotion.state,
            child: _testing
                ? SizedBox.square(
                    key: const ValueKey('loading'),
                    dimension: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: surge.textSecondary,
                    ),
                  )
                : Icon(
                    SurgeIcons.networkPing,
                    key: const ValueKey('icon'),
                    size: 15,
                    color: surge.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _ProfileProxyPreviewCard extends StatelessWidget {
  const _ProfileProxyPreviewCard({required this.proxy});

  final Proxy proxy;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                EmojiText(
                  proxy.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typography.previewLabel.copyWith(
                    color: surge.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  proxy.type,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typography.supporting.copyWith(
                    color: surge.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ProfileDelayBadge(proxy: proxy),
        ],
      ),
    );
  }
}

class _ProfileDelayBadge extends ConsumerWidget {
  const _ProfileDelayBadge({required this.proxy});

  final Proxy proxy;

  Future<void> _handleTest(WidgetRef ref) async {
    final testUrl = ref.read(realTestUrlProvider(null));
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    final identity = proxiesAction.captureRuntimeProfileIdentity();
    if (identity == null || !proxiesAction.isRuntimeIdentityActive(identity)) {
      return;
    }
    proxiesAction.setDelayForRuntimeIdentity(
      identity,
      Delay(url: testUrl, name: proxy.name, value: 0),
    );
    try {
      proxiesAction.setDelayForRuntimeIdentity(
        identity,
        await coreController.getDelay(testUrl, proxy.name),
      );
    } catch (e) {
      commonPrint.log('_ProfileDelayBadge test failed for ${proxy.name}: $e');
      proxiesAction.setDelayForRuntimeIdentity(
        identity,
        Delay(url: testUrl, name: proxy.name, value: -1),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: null),
    );
    return SurgeDelayPill(delay: delay, onTap: () => _handleTest(ref));
  }
}

class _ProfileListContainer extends StatelessWidget {
  const _ProfileListContainer({
    required this.profiles,
    required this.currentProfileId,
    required this.onSelect,
  });

  final List<Profile> profiles;
  final int? currentProfileId;
  final void Function(int? profileId) onSelect;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(surge.radii.list),
      child: Column(
        children: [
          for (var i = 0; i < profiles.length; i++)
            _ProfileListItem(
              profile: profiles[i],
              isSelected: profiles[i].id == currentProfileId,
              showDivider: i != profiles.length - 1,
              isFirst: i == 0,
              isLast: i == profiles.length - 1,
              onTap: () => onSelect(profiles[i].id),
            ),
        ],
      ),
    );
  }
}

class _ProfileListItem extends StatelessWidget {
  const _ProfileListItem({
    required this.profile,
    required this.isSelected,
    required this.showDivider,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  final Profile profile;
  final bool isSelected;
  final bool showDivider;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  Future<void> _handleDeleteProfile(BuildContext context) async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: appLocalizations.deleteTip(appLocalizations.profile),
      ),
    );
    if (res != true) return;
    await globalState.container
        .read(profilesActionProvider.notifier)
        .deleteProfile(profile.id);
  }

  Future<void> _handlePreview(BuildContext context) async {
    BaseNavigator.push<String>(context, PreviewProfileView(profile: profile));
  }

  Future<void> _updateProfile() async {
    if (profile.type == ProfileType.file) return;
    await globalState.loadingRun(() async {
      await globalState.container
          .read(profilesActionProvider.notifier)
          .updateProfile(profile, showLoading: true, publishInput: false);
    }, tag: LoadingTag.profiles);
  }

  void _handleShowEditExtendPage(BuildContext context) {
    showSheet(
      context: context,
      props: const SheetProps(isScrollControlled: true),
      builder: (_) {
        return FractionallySizedBox(
          heightFactor: 0.75,
          child: EditProfileView(profile: profile, context: context),
        );
      },
    );
  }

  Future<void> _handleCopyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: profile.url));
    if (context.mounted) {
      context.showNotifier(context.appLocalizations.copySuccess);
    }
  }

  Future<void> _handleExportFile(BuildContext context) async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.safeRun<bool>(() async {
      final mFile = await profile.file;
      final value = await picker.saveFile(
        profile.realLabel,
        mFile.readAsBytesSync(),
      );
      if (value == null) return false;
      return true;
    }, title: appLocalizations.tip);
    if (res == true && context.mounted) {
      context.showNotifier(appLocalizations.exportSuccess);
    }
  }

  void _handlePushGenProfilePage(BuildContext context, int id) {
    BaseNavigator.push(context, OverwriteView(profileId: id));
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final hasTraffic =
        profile.subscriptionInfo != null && profile.subscriptionInfo!.total > 0;
    final trailingAction = SizedBox.square(
      dimension: 44,
      child: Consumer(
        builder: (_, ref, _) {
          final isUpdating = ref.watch(isUpdatingProvider(profile.updatingKey));
          return FadeThroughBox(
            child: isUpdating
                ? Center(
                    key: const ValueKey('loading'),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: surge.textSecondary,
                      ),
                    ),
                  )
                : _ProfileActionButton(
                    onEdit: () {
                      _handleShowEditExtendPage(context);
                    },
                    onPreview: () {
                      _handlePreview(context);
                    },
                    onSync: profile.type == ProfileType.url
                        ? _updateProfile
                        : null,
                    onOverride: () {
                      _handlePushGenProfilePage(context, profile.id);
                    },
                    onCopyLink: profile.type == ProfileType.url
                        ? () {
                            _handleCopyLink(context);
                          }
                        : null,
                    onExport: () {
                      _handleExportFile(context);
                    },
                    onDelete: () {
                      _handleDeleteProfile(context);
                    },
                  ),
          );
        },
      ),
    );
    return SurgeSelectableRow(
      selected: isSelected,
      onTap: onTap,
      presentation: SurgeSelectionPresentation.subtle,
      position: isFirst
          ? isLast
                ? SurgeSelectableRowPosition.single
                : SurgeSelectableRowPosition.first
          : isLast
          ? SurgeSelectableRowPosition.last
          : SurgeSelectableRowPosition.middle,
      radius: surge.radii.list,
      showDivider: showDivider,
      child: SizedBox(
        height: hasTraffic ? 92 : 74,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: hasTraffic
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ProfileTextBlock(
                            profile: profile,
                            showTypePill: true,
                            info: [_ProfileListSummary(profile: profile)],
                          ),
                          const SizedBox(height: 7),
                          SizedBox(
                            width: double.infinity,
                            child: _ProfileCombinedSummary(profile: profile),
                          ),
                        ],
                      )
                    : _ProfileTextBlock(
                        profile: profile,
                        showTypePill: true,
                        info: [_ProfileListSummary(profile: profile)],
                      ),
              ),
              const SizedBox(width: 10),
              trailingAction,
            ],
          ),
        ),
      ),
    );
  }
}

class ProfileItem extends StatelessWidget {
  final Profile profile;
  final int? groupValue;
  final void Function(int? value) onChanged;

  const ProfileItem({
    super.key,
    required this.profile,
    required this.groupValue,
    required this.onChanged,
  });

  Future<void> _handleDeleteProfile(BuildContext context) async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: appLocalizations.deleteTip(appLocalizations.profile),
      ),
    );
    if (res != true) {
      return;
    }
    await globalState.container
        .read(profilesActionProvider.notifier)
        .deleteProfile(profile.id);
  }

  Future<void> _handlePreview(BuildContext context) async {
    BaseNavigator.push<String>(context, PreviewProfileView(profile: profile));
  }

  Future updateProfile() async {
    if (profile.type == ProfileType.file) return;
    await globalState.loadingRun(() async {
      await globalState.container
          .read(profilesActionProvider.notifier)
          .updateProfile(profile, showLoading: true, publishInput: false);
    }, tag: LoadingTag.profiles);
  }

  void _handleShowEditExtendPage(BuildContext context) {
    showSheet(
      context: context,
      props: const SheetProps(isScrollControlled: true),
      builder: (_) {
        return FractionallySizedBox(
          heightFactor: 0.75,
          child: EditProfileView(profile: profile, context: context),
        );
      },
    );
  }

  List<Widget> _buildUrlProfileInfo(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final subscriptionInfo = profile.subscriptionInfo;
    return [
      const SizedBox(height: 6),
      if (subscriptionInfo != null)
        SubscriptionInfoView(subscriptionInfo: subscriptionInfo),
      LastUpdateTimeText(
        lastUpdateDate: profile.lastUpdateDate,
        style: context.typography.detailLabel.copyWith(
          color: surge.textSecondary,
        ),
      ),
    ];
  }

  List<Widget> _buildFileProfileInfo(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return [
      const SizedBox(height: 6),
      LastUpdateTimeText(
        lastUpdateDate: profile.lastUpdateDate,
        style: context.typography.detailLabel.copyWith(
          color: surge.textSecondary,
        ),
      ),
    ];
  }

  Future<void> _handleCopyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: profile.url));
    if (context.mounted) {
      context.showNotifier(context.appLocalizations.copySuccess);
    }
  }

  Future<void> _handleExportFile(BuildContext context) async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.safeRun<bool>(() async {
      final mFile = await profile.file;
      final value = await picker.saveFile(
        profile.realLabel,
        mFile.readAsBytesSync(),
      );
      if (value == null) return false;
      return true;
    }, title: appLocalizations.tip);
    if (res == true && context.mounted) {
      context.showNotifier(appLocalizations.exportSuccess);
    }
  }

  void _handlePushGenProfilePage(BuildContext context, int id) {
    BaseNavigator.push(context, OverwriteView(profileId: id));
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final isSelected = profile.id == groupValue;
    return Consumer(
      builder: (_, ref, _) {
        final dynamicColor = ref.watch(
          themeSettingProvider.select((state) => state.dynamicColor),
        );
        final selectedBorderColor = !dynamicColor
            ? surge.semantic.profileSelectionBorderFixed
            : surge.primary;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            SurgeCard(
              backgroundColor: isSelected ? surge.selectedFill : surge.card,
              border: Border.all(
                color: isSelected ? selectedBorderColor : surge.separator,
                width: 0.5,
              ),
              shadow: false,
              borderRadius: surge.radii.list,
              padding: EdgeInsets.zero,
              onTap: () {
                onChanged(profile.id);
              },
              child: Padding(
                key: Key(profile.id.toString()),
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: _ProfileTextBlock(
                        profile: profile,
                        info: switch (profile.type) {
                          ProfileType.file => _buildFileProfileInfo(context),
                          ProfileType.url => _buildUrlProfileInfo(context),
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    _ProfilePill(
                      label: profile.type.name,
                      color: surge.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 40,
                      width: 40,
                      child: Consumer(
                        builder: (_, ref, _) {
                          final isUpdating = ref.watch(
                            isUpdatingProvider(profile.updatingKey),
                          );
                          return FadeThroughBox(
                            child: isUpdating
                                ? const Padding(
                                    key: ValueKey('loading'),
                                    padding: EdgeInsets.all(9),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : _ProfileActionButton(
                                    onEdit: () {
                                      _handleShowEditExtendPage(context);
                                    },
                                    onPreview: () {
                                      _handlePreview(context);
                                    },
                                    onSync: profile.type == ProfileType.url
                                        ? updateProfile
                                        : null,
                                    onOverride: () {
                                      _handlePushGenProfilePage(
                                        context,
                                        profile.id,
                                      );
                                    },
                                    onCopyLink: profile.type == ProfileType.url
                                        ? () {
                                            _handleCopyLink(context);
                                          }
                                        : null,
                                    onExport: () {
                                      _handleExportFile(context);
                                    },
                                    onDelete: () {
                                      _handleDeleteProfile(context);
                                    },
                                  ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 10,
              top: -6,
              child: AnimatedScale(
                scale: isSelected ? 1 : 0.65,
                duration: SurgeMotion.state,
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: isSelected ? 1 : 0,
                  duration: SurgeMotion.state,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: surge.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: surge.card, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: surge.shadow,
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.onEdit,
    required this.onPreview,
    required this.onOverride,
    required this.onExport,
    required this.onDelete,
    this.onSync,
    this.onCopyLink,
  });

  final VoidCallback onEdit;
  final VoidCallback onPreview;
  final VoidCallback? onSync;
  final VoidCallback onOverride;
  final VoidCallback? onCopyLink;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonPopupBox(
      key: const ValueKey('menu'),
      popup: _ProfileActionMenu(
        children: [
          _ProfileActionMenuItem(
            icon: SurgeIcons.editFilled,
            label: appLocalizations.edit,
            onTap: onEdit,
          ),
          _ProfileActionMenuItem(
            icon: SurgeIcons.visibilityFilled,
            label: appLocalizations.preview,
            onTap: onPreview,
          ),
          if (onSync != null)
            _ProfileActionMenuItem(
              icon: SurgeIcons.sync,
              label: appLocalizations.sync,
              onTap: onSync!,
            ),
          _ProfileActionMenuItem(
            icon: SurgeIcons.tune,
            label: appLocalizations.override,
            onTap: onOverride,
          ),
          if (onCopyLink != null)
            _ProfileActionMenuItem(
              icon: SurgeIcons.link,
              label: appLocalizations.copyLink,
              onTap: onCopyLink!,
            ),
          _ProfileActionMenuItem(
            icon: SurgeIcons.share,
            label: appLocalizations.exportFile,
            onTap: onExport,
          ),
          _ProfileActionMenuItem(
            icon: SurgeIcons.delete,
            label: appLocalizations.delete,
            danger: true,
            onTap: onDelete,
          ),
        ],
      ),
      targetBuilder: (open) {
        return SoftOsIconButton(
          icon: SurgeIcons.more,
          onPressed: open,
          visualSize: 30,
          tapSize: 44,
          iconSize: 16,
        );
      },
    );
  }
}

class _ProfileActionMenu extends StatelessWidget {
  const _ProfileActionMenu({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return SurgeCard(
      shadow: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      borderRadius: 14,
      border: Border.all(color: surge.separator.withValues(alpha: 0.7)),
      child: IntrinsicWidth(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 188),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

class _ProfileActionMenuItem extends StatelessWidget {
  const _ProfileActionMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final color = danger
        ? surge.red.withValues(alpha: 0.88)
        : surge.textPrimary.withValues(alpha: 0.72);
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: danger
                    ? surge.red.withValues(alpha: 0.075)
                    : surge.textSecondary.withValues(alpha: 0.055),
                borderRadius: BorderRadius.circular(surge.radii.button),
              ),
              child: Icon(icon, size: 15.5, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typography.controlLabel.copyWith(
                  color: danger ? color : surge.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTextBlock extends StatelessWidget {
  const _ProfileTextBlock({
    required this.profile,
    this.info = const [],
    this.showTypePill = false,
  });

  final Profile profile;
  final List<Widget> info;
  final bool showTypePill;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                profile.realLabel,
                style: context.typography.rowTitle.copyWith(
                  color: surge.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showTypePill) ...[
              const SizedBox(width: 7),
              _ProfileTypeLabel(type: profile.type),
            ],
          ],
        ),
        if (info.isNotEmpty)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: info,
          ),
      ],
    );
  }
}

class _ProfileTypeLabel extends StatelessWidget {
  const _ProfileTypeLabel({required this.type});

  final ProfileType type;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final baseColor = switch (type) {
      ProfileType.url => surge.semantic.dashboardActiveGreen,
      ProfileType.file => surge.semantic.dashboardDynamicActive,
    };
    final color = Color.lerp(baseColor, surge.textPrimary, 0.12)!;
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        type.name.toUpperCase(),
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: SlclashTypeScale.profileTypeLabel.copyWith(
          color: color.withValues(alpha: 0.92),
        ),
      ),
    );
  }
}

class _ProfileListSummary extends StatelessWidget {
  const _ProfileListSummary({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final subscriptionInfo = profile.subscriptionInfo;
    final hasTraffic = subscriptionInfo != null && subscriptionInfo.total > 0;
    final used = hasTraffic
        ? subscriptionInfo.upload + subscriptionInfo.download
        : 0;
    final total = hasTraffic ? subscriptionInfo.total : 0;
    final progress = hasTraffic ? (used / total).clamp(0.0, 1.0) : 0.0;
    final detailStyle = context.typography.detailLabel.copyWith(
      color: surge.textSecondary,
    );

    if (!hasTraffic) {
      return Padding(
        padding: const EdgeInsets.only(top: 5),
        child: _ProfileUpdateSummary(profile: profile, style: detailStyle),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: SoftOsUsageBar(value: progress),
    );
  }
}

class SoftOsUsageBar extends StatelessWidget {
  const SoftOsUsageBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final progress = value.clamp(0.0, 1.0);
    final color = progress >= 0.95
        ? surge.red.withValues(alpha: 0.82)
        : progress >= 0.8
        ? surge.orange.withValues(alpha: 0.78)
        : surge.primary.withValues(alpha: 0.72);

    return ClipRRect(
      borderRadius: BorderRadius.circular(2.5),
      child: LinearProgressIndicator(
        minHeight: 5,
        value: progress,
        color: color,
        backgroundColor: surge.textSecondary.withValues(alpha: 0.08),
      ),
    );
  }
}

class _ProfileCombinedSummary extends StatelessWidget {
  const _ProfileCombinedSummary({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final subscriptionInfo = profile.subscriptionInfo!;
    final used = subscriptionInfo.upload + subscriptionInfo.download;
    final trafficText =
        '${used.traffic.show} / ${subscriptionInfo.total.traffic.show}';
    final expireText = subscriptionInfo.expire != 0
        ? DateTime.fromMillisecondsSinceEpoch(
            subscriptionInfo.expire * 1000,
          ).show.toString()
        : context.appLocalizations.neverExpires;
    final style = context.typography.detailLabel.copyWith(
      color: surge.textSecondary,
    );
    if (profile.lastUpdateDate == null) {
      return _SummaryText(text: '$trafficText · $expireText', style: style);
    }
    return TickBuilder(
      duration: const Duration(minutes: 1),
      builder: (context, _) => _SummaryText(
        text:
            '${profile.lastUpdateDate!.getLastUpdateTimeDesc(context)} · $trafficText · $expireText',
        style: style,
      ),
    );
  }
}

class _ProfileUpdateSummary extends StatelessWidget {
  const _ProfileUpdateSummary({required this.profile, required this.style});

  final Profile profile;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (profile.lastUpdateDate == null) {
      return _SummaryText(
        text: profile.type == ProfileType.file
            ? context.appLocalizations.localFile
            : '',
        style: style,
      );
    }
    final prefix = profile.type == ProfileType.file
        ? '${context.appLocalizations.localFile} · '
        : '';
    return TickBuilder(
      duration: const Duration(minutes: 1),
      builder: (context, _) {
        return _SummaryText(
          text:
              '$prefix${profile.lastUpdateDate!.getLastUpdateTimeDesc(context)}',
          style: style,
        );
      },
    );
  }
}

class _SummaryText extends StatelessWidget {
  const _SummaryText({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

class _ProfilePill extends StatelessWidget {
  const _ProfilePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final metrics = SoftOsMetrics.of(context);
    const backgroundAlpha = 0.055;
    const borderAlpha = 0.38;
    final textColor = surge.textPrimary.withValues(alpha: 0.68);
    final height = metrics.value(surge.controls.statusPillHeight);
    return Container(
      height: height,
      constraints: BoxConstraints(
        minWidth: metrics.value(48),
        maxWidth: metrics.value(64),
      ),
      padding: EdgeInsets.symmetric(horizontal: metrics.value(10)),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: backgroundAlpha),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(
          color: surge.separator.withValues(alpha: borderAlpha),
          width: surge.spacing.hairline,
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          maxLines: 1,
          textScaler: TextScaler.noScaling,
          style: context.typography.badgeLabel.copyWith(color: textColor),
        ),
      ),
    );
  }
}

class LastUpdateTimeText extends StatelessWidget {
  final DateTime? lastUpdateDate;
  final TextStyle? style;

  const LastUpdateTimeText({
    super.key,
    required this.lastUpdateDate,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    if (lastUpdateDate == null) {
      return Text('', style: style);
    }
    return TickBuilder(
      duration: const Duration(minutes: 1),
      builder: (context, _) {
        return Text(
          lastUpdateDate!.getLastUpdateTimeDesc(context),
          style: style,
        );
      },
    );
  }
}

class ReorderableProfilesSheet extends StatefulWidget {
  final List<Profile> profiles;

  const ReorderableProfilesSheet({super.key, required this.profiles});

  @override
  State<ReorderableProfilesSheet> createState() =>
      _ReorderableProfilesSheetState();
}

class _ReorderableProfilesSheetState extends State<ReorderableProfilesSheet> {
  late List<Profile> profiles;

  @override
  void initState() {
    super.initState();
    profiles = List.from(widget.profiles);
  }

  Widget _buildItem(int index) {
    final position = ItemPosition.get(index, profiles.length);
    final profile = profiles[index];
    return ItemPositionProvider(
      key: Key(profile.id.toString()),
      position: position,
      child: DecorationListItem(
        trailing: ReorderableDelayedDragStartListener(
          index: index,
          child: const Icon(SurgeIcons.dragHandle),
        ),
        title: Text(profile.realLabel),
      ),
    );
  }

  void _handleSave() {
    Navigator.of(context).pop();
    globalState.container.read(profilesProvider.notifier).reorder(profiles);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return AdaptiveSheetScaffold(
      sheetTransparentToolBar: true,
      appBarActions: [
        SlAppBarIconAction(
          icon: SurgeIcons.confirm,
          tooltip: appLocalizations.confirm,
          onPressed: _handleSave,
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.only(bottom: 32),
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
          ).copyWith(top: context.sheetTopPadding),
          proxyDecorator: (child, index, animation) {
            return commonProxyDecorator(_buildItem(index), index, animation);
          },
          onReorder: (oldIndex, newIndex) {
            setState(() {
              reorderProfileList(profiles, oldIndex, newIndex);
            });
          },
          itemBuilder: (_, index) {
            return _buildItem(index);
          },
          itemCount: profiles.length,
        ),
      ),
      title: appLocalizations.profilesSort,
    );
  }
}
