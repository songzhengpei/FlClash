# 三处 IPv6 设置的语义与合并评估

日期：2026-09-11。范围：当前 Android / arm64 分支及本地 Mihomo 源码。只做调研，不调整设置、默认值或运行配置。

## 结论

可以合并入口，但不能无损地把三个字段合并为一个开关。推荐一个集中入口，采用预设模式 + 高级自定义；底层继续保留三个偏好及 DNS 来源。若当前目标只是降低理解成本，先集中入口并改名是风险最低的方案。

三个字段并非三个重复的“是否支持 IPv6”。它们分别控制 Android 接管、内核解析/连接策略、DNS 普通 AAAA 应答。手机到代理节点的连接与代理节点到目标网站的连接，也不能混为一谈。

## 实际作用

| 当前位置 | 实际字段 | 作用 | 不能据此推断 |
|---|---|---|---|
| 网络 | vpnProps.ipv6 → VpnOptions.ipv6 | 向 Android VPN 添加 IPv6 接口地址、路由、DNS 地址，并加入对应 DNS 接管目标；修改需要重建实例 | 开启就一定有可用 IPv6 出口，或所有应用都走 VPN |
| 基本设置 | patchClashConfig.ipv6 → YAML 顶层 ipv6 | 设置 resolver.DisableIPv6，并作为 DNS 实例 IPv6 的上限，影响内核域名解析/连接选择；本 APP 总是覆写订阅该顶层字段 | 关闭即构成所有 IPv6 流量的防火墙；所有显式 IP、Hosts、协议路径都必然被禁止 |
| DNS | patchClashConfig.dns.ipv6 | APP 管理 DNS 时控制普通 AAAA 查询的处理；关闭通常返回空 AAAA 答案；还受基础开关限制 | 关闭 DNS 的 IPv6 就不能通过 IPv6 连接 DNS 服务器，或能禁止 APP 自带 DoH/已缓存地址 |

网络开关关闭时，当前实现不添加 IPv6 地址/路由/DNS，也未调用 allowFamily(AF_INET6)。Android 文档规定该地址族默认被阻断。因此对 VPN 管理的应用，它通常不是“绕过 VPN 使用 IPv6”。不适用于未纳入 VPN 的应用、受保护的内核上游 socket 等所有场景。

基础开关的名称“内核 IPv6 能力”仍过于宽泛。本地 resolver 代码明确把它用于是否解析 IPv6；Hosts、显式地址和特定协议路径需要分别分析，不能把它当成严格的全局禁用保证。

DNS 应答开关也不是万能过滤器。本地 DNS middleware 在普通 resolver 之前还可能处理 Hosts/fake-ip；APP 自带加密 DNS不受这个字段直接控制。因此下面公式和组合表描述的是普通 DNS 路径，不是所有 DNS 包的绝对保证。

## DNS 来源与有效状态

令 N=网络接管、C=基础 IPv6、D=实际 DNS 来源中的 ipv6：普通 DNS IPv6 生效条件为 C && D，不是 N && C && D。

- 使用启用的订阅 DNS且未覆写：D 来自订阅。DNS 页保存的 APP 开关仅是禁用预设，不能当作当前有效值。
- APP 覆写或自动补全：D 来自 APP 预设。
- C 关闭：合成逻辑将运行 DNS IPv6 置 false，保留原偏好；Mihomo executor 本身也采用 c.IPv6 && generalIPv6。
- N 不参与这项计算。因此 N=关、C=开、D=开时可能向普通应用返回 IPv6 地址，但 VPN 不承接该地址族，造成连接失败或回退等待。

不能为了让“开启 IPv6”一键有效，偷偷开启整个 DNS 覆写：那会同时改变 DNS 服务器等其他配置的所有权。

## 八种组合

表中 D 是实际来源值，非一定等于 DNS 页开关；开关仅代表允许，不保证线路可用。

| N | C | D | 普通 AAAA | 场景与限制 |
|---|---|---|---|---|
| 关 | 关 | 关 | 关 | 常规 IPv4 配置 |
| 关 | 关 | 开 | 关 | DNS 偏好保留但受基础限制 |
| 关 | 开 | 关 | 关 | 不承接普通应用 IPv6，但保留内核 IPv6 相关能力；高级组合，具体节点解析仍受 DNS 路径影响 |
| 关 | 开 | 开 | 开 | 普通 TUN 应用容易出现应答与接管不匹配；HTTP/SOCKS 域名代理等场景不等同于此，不能一概删除 |
| 开 | 关 | 关 | 关 | 接管范围与内核策略不匹配，不适合作普通预设；仍不是所有显式 IPv6 流量必然失败的证明 |
| 开 | 关 | 开 | 关 | 同上，另保留未生效 DNS 偏好 |
| 开 | 开 | 关 | 关 | 接管 IPv6，但不主动通过普通 DNS 发布 AAAA；可用于控制域名优先级、兼容性排障，已知 IPv6 目标仍有价值 |
| 开 | 开 | 开 | 开 | 常规双栈意图，仍取决于节点、物理网络、路由和目标能力 |

其中 110 是明确不应被二态总开关抹掉的组合。010/011 可涉及代理端口访问和内核上游，与手机应用 TUN 入站的需求不同，不能用“少见”代替兼容性验证。

## 合并方案

| 方案 | 好处 | 代价 | 建议 |
|---|---|---|---|
| 三个字段永久强制同值 | UI 最简单 | 8 种偏好压成 2 种；破坏旧偏好、DNS 所有权和高级组合 | 不推荐 |
| 只合并网络与基础，DNS 独立 | 普通用户更易理解 | 仍会丢失内核上游/代理端口与 TUN 分离的控制 | 不作为无损方案 |
| 三个控件集中并改名 | 不改行为，不需要迁移偏好 | 仍有三个可选项 | 最低风险的第一步 |
| 单一入口 + 预设 + 自定义 | 普通用户容易使用，高级场景保留 | 需要设计来源显示、事务和旧配置映射 | 推荐最终形态 |

建议入口放在“网络 → IPv6”，其他页面只显示关联状态/跳转，不再出现三个同名开关。

建议预设：
1. IPv4 模式：N/C 关闭，保留 DNS 偏好，说明不是手机系统级 IPv6 禁用。
2. IPv6 模式：N/C 开启；APP 管理 DNS 时开启 APP 的 AAAA；订阅管理 DNS 时继续尊重订阅，并显示“DNS 跟随订阅：开启/关闭”。因此不能把此模式命名成“保证完整双栈”。
3. 自定义：显示“VPN 接管 IPv6”“内核 IPv6 解析”“DNS 返回 IPv6 地址”及来源/有效状态，支持原组合。

如果产品一定要“开=三项全部有效”，必须另行明确只覆写 DNS IPv6 字段的所有权，这属于新的行为设计，不能悄悄纳入 UI 合并。

## 升级与兼容性

首次升级只识别现有组合，不自动改字段。无法准确映射的组合显示自定义。禁止使用任意一项为真就全开的迁移，也不要全关后丢弃用户的 DNS 偏好。切换订阅只更新 DNS 来源与显示，不强迫用户回到某个模式。

预设提交必须一次性修改相关字段，让现有协调器完成一次必要的 VPN 重建/配置应用，失败按整批回退。停止或智能暂停时只保存。不要加基于单次网络探测的自动开关：物理网络有 IPv6、节点能访问 IPv6、目标可达是不同判断。

必须验证的场景：
- IPv4-only、正常双栈、IPv6-only/DNS64/NAT64 网络；IPv6 存在但质量不佳。
- IPv4 节点访问 IPv6 目标、IPv6 节点、直连、HTTP/SOCKS 域名代理。
- 订阅 DNS/APP 覆写/自动补全，fake-ip/普通 DNS、Hosts 与应用自带 DoH。
- IPv4/IPv6 自定义路由、分应用访问控制、协议栈差异。
- 八种旧偏好迁移、切换订阅、停止/暂停、批量失败回退。

当前证据：已核对代码，并存在八种组合的合成/参数测试及上一轮部分 IPv6 真机记录；没有完成以上所有网络条件的端到端真机验证。因此本报告是可行性评估，不能视为合并后的兼容性验收。

## 当前说明中的问题

- DNS 页中文“还需网络页启用 IPv6 接管”缺少“通过 TUN 的普通应用”限定；代理端口/远端解析不完全适用。
- alignDnsIpv6WithCore 注释声称依据 TUN 是否启用 IPv6，实际只接收 coreIpv6。这是注释与实现不一致，不能拿该注释当成三个开关联动的证据。
- 页面应区分保存偏好与实际来源值，尤其是订阅 DNS；避免把置灰的 APP 预设显示成当前状态。

## 依据

本地源码（以本地 fork 为准，在线文档可能随上游变化）：
- lib/services/settings/settings_contract.dart：settingsVpnOptions、有效参数分类。
- android/service/src/main/java/com/follow/clash/service/VpnService.kt：handleStart 的接口、路由和 DNS 配置。
- lib/common/task.dart：顶层 IPv6 覆写、DNS 来源合成、alignDnsIpv6WithCore。
- lib/services/mihomo_config/runtime_config_patch.dart：DNS IPv6 上限。
- core/Clash.Meta/hub/executor/executor.go：updateDNS、resolver.DisableIPv6。
- core/Clash.Meta/component/resolver/resolver.go：IPv6 lookup 与 Hosts 分支。
- core/Clash.Meta/dns/middleware.go：普通 AAAA 与前置 middleware。
- test/mihomo/runtime_config_ownership_test.dart：八种组合和来源测试。

外部一手资料：
- [Android VpnService.Builder](https://developer.android.com/reference/android/net/VpnService.Builder)：地址族默认阻断、地址与路由配置规则。
- [Mihomo 全局配置](https://wiki.metacubex.one/config/general/)：顶层 IPv6 字段；上游默认值不能直接作为本 APP 默认值。
- [Mihomo DNS 配置](https://wiki.metacubex.one/config/dns/)：DNS IPv6 与 AAAA 应答语义。
