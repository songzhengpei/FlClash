import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TrackerInfoItem extends ConsumerWidget {
  final TrackerInfo trackerInfo;
  final Function(String)? onClickKeyword;
  final Widget? trailing;
  final String detailTitle;
  final bool showDivider;

  const TrackerInfoItem({
    super.key,
    required this.trackerInfo,
    this.onClickKeyword,
    this.trailing,
    required this.detailTitle,
    this.showDivider = true,
  });

  static double get subTitleHeight {
    return globalState.measure.bodySmallHeight + 20;
  }

  static Future<ImageProvider?> _getPackageIcon(TrackerInfo connection) async {
    return await app?.getPackageIcon(connection.metadata.process);
  }

  String _getSourceText(BuildContext context, TrackerInfo trackerInfo) {
    final progress = trackerInfo.progressText.isNotEmpty
        ? '${trackerInfo.progressText} · '
        : '';
    final traffic = Traffic(up: trackerInfo.upload, down: trackerInfo.download);
    return '${trackerInfo.start.getLastUpdateTimeDesc(context)} · $progress${traffic.desc}';
  }

  @override
  Widget build(BuildContext context, ref) {
    final surge = SurgeTheme.of(context);
    final showProcessIcon = ref.watch(
      patchClashConfigProvider.select(
        (state) =>
            state.findProcessMode == FindProcessMode.always && system.isAndroid,
      ),
    );
    final process = trackerInfo.metadata.process;

    return SurgePressable(
      scaleFeedback: false,
      overlayInsets: EdgeInsets.symmetric(vertical: surge.spacing.hairline),
      overlayBaseColor: surge.card,
      onTap: () {
        showExtend(
          context,
          builder: (_) {
            return AdaptiveSheetScaffold(
              body: TrackerInfoDetailView(trackerInfo: trackerInfo),
              title: detailTitle,
              appBarActions: const [],
            );
          },
        );
      },
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 58),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showProcessIcon && process.isNotEmpty)
                        _TrackerProcessIcon(
                          trackerInfo: trackerInfo,
                          onTap: onClickKeyword == null
                              ? null
                              : () => onClickKeyword!(process),
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              trackerInfo.desc,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.typography.rowTitle.copyWith(
                                color: surge.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              _getSourceText(context, trackerInfo),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.typography.techLabel.copyWith(
                                color: surge.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (trailing != null) ...[
                        const SizedBox(width: 6),
                        trailing!,
                      ],
                    ],
                  ),
                  if (trackerInfo.chains.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 28,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.zero,
                        itemCount: trackerInfo.chains.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (_, index) {
                          final chain = trackerInfo.chains[index];
                          return _TrackerChainPill(
                            label: chain,
                            onTap: onClickKeyword == null
                                ? null
                                : () => onClickKeyword!(chain),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (showDivider)
            const Positioned(
              left: 16,
              right: 16,
              bottom: 0,
              child: SoftOsListDivider(),
            ),
        ],
      ),
    );
  }
}

class SoftOsListSurface extends StatelessWidget {
  const SoftOsListSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SurgeListSurface(child: child);
  }
}

class SoftOsListDivider extends StatelessWidget {
  const SoftOsListDivider({super.key, this.alpha = 0.56});

  final double alpha;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Divider(
      height: 0,
      thickness: surge.spacing.hairline,
      color: surge.separator.withValues(alpha: alpha),
    );
  }
}

class _TrackerProcessIcon extends StatelessWidget {
  const _TrackerProcessIcon({required this.trackerInfo, this.onTap});

  final TrackerInfo trackerInfo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return FutureBuilder<ImageProvider?>(
      future: TrackerInfoItem._getPackageIcon(trackerInfo),
      builder: (_, snapshot) {
        if (!snapshot.hasData || snapshot.data == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(right: 10),
          child: SurgePressable(
            compact: true,
            borderRadius: BorderRadius.circular(surge.radii.compact),
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(surge.radii.compact),
              child: Image(
                image: snapshot.data!,
                gaplessPlayback: true,
                width: 34,
                height: 34,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackerChainPill extends StatelessWidget {
  const _TrackerChainPill({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(surge.radii.smallCard),
        child: Ink(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: surge.textSecondary.withValues(alpha: 0.055),
            borderRadius: BorderRadius.circular(surge.radii.smallCard),
            border: Border.all(
              color: surge.separator.withValues(alpha: 0.35),
              width: surge.spacing.hairline,
            ),
          ),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typography.techLabel.copyWith(
                color: surge.textPrimary.withValues(alpha: 0.72),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TrackerInfoDetailView extends StatelessWidget {
  final TrackerInfo trackerInfo;

  const TrackerInfoDetailView({super.key, required this.trackerInfo});

  String _getRuleText() {
    final rule = trackerInfo.rule;
    final rulePayload = trackerInfo.rulePayload;
    if (rulePayload.isNotEmpty) {
      return '$rule($rulePayload)';
    }
    return rule;
  }

  String _getProcessText() {
    final process = trackerInfo.metadata.process;
    final uid = trackerInfo.metadata.uid;
    if (uid != 0) {
      return '$process($uid)';
    }
    return process;
  }

  String _getSourceText() {
    final sourceIP = trackerInfo.metadata.sourceIP;
    if (sourceIP.isEmpty) {
      return '';
    }
    final sourcePort = trackerInfo.metadata.sourcePort;
    if (sourcePort.isNotEmpty) {
      return '$sourceIP:$sourcePort';
    }
    return sourceIP;
  }

  String _getDestinationText() {
    final destinationIP = trackerInfo.metadata.destinationIP;
    if (destinationIP.isEmpty) {
      return '';
    }
    final destinationPort = trackerInfo.metadata.destinationPort;
    if (destinationPort.isNotEmpty) {
      return '$destinationIP:$destinationPort';
    }
    return destinationIP;
  }

  Widget _buildChains(BuildContext context) {
    final chains = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        for (final chain in trackerInfo.chains)
          CommonChip(label: chain, onPressed: () {}),
      ],
    );
    return ListItem(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 20,
        children: [
          Text(context.appLocalizations.proxyChains),
          Flexible(child: chains),
        ],
      ),
    );
  }

  Widget _buildItem({
    required String title,
    required String desc,
    bool quickCopy = false,
  }) {
    return ListItem(
      title: Row(
        spacing: 16,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: 4,
            children: [
              Text(title),
              if (quickCopy)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      SurgeIcons.copy,
                      size: SurgeIconSize.compact,
                    ),
                    onPressed: () {},
                  ),
                ),
            ],
          ),
          Flexible(child: Text(desc, textAlign: TextAlign.end)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final items = [
      _buildItem(
        title: appLocalizations.creationTime,
        desc: trackerInfo.start.showFull,
      ),
      if (_getProcessText().isNotEmpty)
        _buildItem(title: appLocalizations.process, desc: _getProcessText()),
      _buildItem(
        title: appLocalizations.networkType,
        desc: trackerInfo.metadata.network,
      ),
      _buildItem(title: appLocalizations.rule, desc: _getRuleText()),
      if (trackerInfo.metadata.host.isNotEmpty)
        _buildItem(
          title: appLocalizations.host,
          desc: trackerInfo.metadata.host,
        ),
      if (_getSourceText().isNotEmpty)
        _buildItem(title: appLocalizations.source, desc: _getSourceText()),
      if (_getDestinationText().isNotEmpty)
        _buildItem(
          title: appLocalizations.destination,
          desc: _getDestinationText(),
        ),
      _buildItem(
        title: appLocalizations.upload,
        desc: trackerInfo.upload.traffic.show,
      ),
      _buildItem(
        title: appLocalizations.download,
        desc: trackerInfo.download.traffic.show,
      ),
      if (trackerInfo.metadata.destinationGeoIP.isNotEmpty)
        _buildItem(
          title: appLocalizations.destinationGeoIP,
          desc: trackerInfo.metadata.destinationGeoIP.join(' '),
        ),
      if (trackerInfo.metadata.destinationIPASN.isNotEmpty)
        _buildItem(
          title: appLocalizations.destinationIPASN,
          desc: trackerInfo.metadata.destinationIPASN,
        ),
      if (trackerInfo.metadata.dnsMode != null)
        _buildItem(
          title: appLocalizations.dnsMode,
          desc: trackerInfo.metadata.dnsMode!.name,
        ),
      if (trackerInfo.metadata.specialProxy.isNotEmpty)
        _buildItem(
          title: appLocalizations.specialProxy,
          desc: trackerInfo.metadata.specialProxy,
        ),
      if (trackerInfo.metadata.specialRules.isNotEmpty)
        _buildItem(
          title: appLocalizations.specialRules,
          desc: trackerInfo.metadata.specialRules,
        ),
      if (trackerInfo.metadata.remoteDestination.isNotEmpty)
        _buildItem(
          title: appLocalizations.remoteDestination,
          desc: trackerInfo.metadata.remoteDestination,
        ),
      _buildChains(context),
    ];
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: items.length,
        itemBuilder: (_, index) {
          return items[index];
        },
      ),
    );
  }
}
