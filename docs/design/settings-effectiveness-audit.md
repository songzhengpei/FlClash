# APP 可见开关有效性调研报告

> 实施跟进：本报告的审计章节描述修改前状态。用户随后批准修复，并要求将常驻状态文字改为 APP 现有提示弹窗。代码修复和验收记录见 [设置自动应用验收记录](settings-application-verification.md)。

## 结论

**现有开关并未整体失效，大部分仍有明确的运行时消费者；但也确实存在已经断开的链路。建议做一次范围明确的“设置有效性修复”，不建议全面重构设置系统或批量删除继承功能。**

最需要处理的是：

1. **网络 → DNS 劫持：已经不能控制实际劫持行为。** Android 创建 TUN 时固定构造劫持地址，不读取 `dnsHijacking`。
2. **网络 → 路由模式 / 路由地址：没有传到 Android VPN。** 这两项虽不是布尔开关，但属于同一组可见控制，影响比一般显示问题更大。
3. **基本设置 → 允许局域网：完整配置可以生效，热更新遗漏字段。** 运行中关闭开关不能据此认为已有监听立即停止接受局域网连接。
4. **订阅 → 自定义覆写 → 规则：不解析域名、匹配源 IP 两个开关回调为空。** 这是界面交互断路，不是内核不支持。
5. **DNS、追加系统 DNS、Geodata 加载器等设置存在“保存了，但没有从当前页面主动应用”的问题。** 重新生成并应用配置后有消费者，不能称为永久失效。
6. **访问控制的显示过滤会在保存时裁剪选择列表。** “隐藏系统应用”不完全是只改变显示，可能改变原有访问控制集合。

与此同时，退出时最小化、自动运行、隐藏最近任务、切页动画、自动关闭连接、仅统计代理、自动检查更新、动态颜色、文本缩放、智能暂停等均找到实质消费路径。没有证据支持为了“来自旧项目”而重写它们。[^1][^2][^3][^4][^5][^6]

## 范围与证据边界

本报告针对当前工作区中的 Android / arm64 版本。应用仓库 HEAD 为 `e5f20a372a1223d4c467e5b1ad7aa5bc50c2a07c`；内核子模块 HEAD 为 `ac017cdd246ce8bd547653d927e7bf77d7ee73d5`。核查日期为 2026-09-10。

内核子模块在核查前已有本地改动：`adapter/outbound/base.go`、`constant/adapters.go`、`tunnel/statistic/manager.go`、`tunnel/statistic/tracker.go`，以及未跟踪的 `manager_proxy_test.go`。因此“仅统计代理”等涉及统计分类的结论针对当前工作区，**不等同于手机中某个已安装 APK 的行为**。调研阶段未修改业务代码、安装 APK 或改变手机设置；后续实施和真机测试已获用户授权，使用独立的 `com.slclash.app.profile`。

“所有开关”的核查口径为：从当前页面入口出发，检查持久化开关、二级页面中的开关、勾选项及与开关密切相关的枚举 / 输入设置。重点四页共有 **29 个布尔开关入口：网络 6、DNS 8、基本设置 8、应用程序 7**；进阶设置自身是三个导航入口，实际控制位于子页面。其他页面另列清单，不把每一个应用、规则或节点的重复勾选行计为一种独立功能。

本轮完成源码链路核对及已有 Flutter 测试，未进行逐项真机 A/B 流量实验，也未执行 Android Kotlin 测试、Go 全量测试、QuickJS 真机测试。下文的“有效”表示已找到连贯的实现链路，除另有说明外，不表示每个开关都经过真机验证。官网资料仅辅助解释平台语义，判断本 fork 是否接线以本地源码为准。

## 第一性原理：什么才叫开关有效

一个设置真正有效，至少要满足以下条件：

| 环节 | 需要回答的问题 | 常见误判 |
|---|---|---|
| 可达 | Android 当前页面能否实际进入该控件？ | 把遗留类或桌面控件算成当前可见功能 |
| 写入 | 点击是否改变正确的状态，并能持久保存？ | 把控件变色当作功能完成 |
| 传递 | 状态是否进入最终 YAML、IPC 参数或界面消费者？ | 模型中有字段，但序列化 / 桥接丢了 |
| 应用 | 哪个事件使新值进入正在运行的实例？ | 写入偏好设置等于已切换正在运行的 VPN |
| 行为 | 最终消费者是否读取此值，前置条件是什么？ | 配置写入成功，但值被强制覆盖 |
| 可解释 | 用户能否知道实际值、来源和等待条件？ | 条件生效的功能看起来像失效 |

本报告采用四类判断：**链路有效、条件 / 延后生效、明确缺陷、当前不可达的遗留项**。同一开关可能完整应用有效但热更新有缺陷；不能强行只给一个“正常 / 不正常”的标签。

最核心的架构事实是：目前至少存在四套应用机制，而非一套统一的“设置保存即应用”。[^7][^8][^9]

| 设置类别 | 现有路径 | 主要边界 |
|---|---|---|
| APP 显示与行为 | Provider → UI / Action；configProvider → 偏好保存 | UI 重建、下次行为触发或下次初始化 |
| 部分内核基础参数 | updateParamsProvider → CoreManager → updateConfigDebounce → Go updateConfig | 仅覆盖显式列出的字段 |
| DNS / 完整配置字段 | getProfile → makeRealProfileTask → 完整配置提交 | 需要重新合成和应用配置 |
| Android VPN 参数 | sharedStateProvider → VpnOptions → VpnService.Builder / startTun | 通常需要重建 VPN，热更新 Go YAML 无法替代 |

偏好保存本身存在且接线完整：`AppStateManager` 监听 `configProvider`，触发延迟保存；启动读取偏好并通过 `buildConfigOverrides` 恢复。**问题重点在应用与实际消费，不是所有设置都丢了存储。**[^7]

## 一、网络页面逐项核查

| 可见项 / 字段 | 判断 | 实际作用与时机 | 建议 |
|---|---|---|---|
| VPN / `vpn.enable` | 条件有效 | 原生服务按 enable 选择 VPN / 非 VPN 服务路径；运行中改变通常需重启。不是首页启动 / 停止按钮的同义项 | 保留，说明控制流量接管方式 |
| 系统代理 / `vpn.systemProxy` | 条件有效 | Android 10+ 才设置 VPN 网络 HTTP 代理；有分身 / 工作资料等关联用户时主动跳过 | 保留，显示“请求开启”与“实际采用”的差别 |
| 智能暂停 / `smartAutoStop` | 有效 | 配置变动触发同步和判断；可信 IP/CIDR 匹配驱动暂停 / 恢复，存在原生策略 | 保留现有实现 |
| 允许绕过 / `allowBypass` | 条件有效 | VPN Builder 调用 `allowBypass()`；允许应用主动绑定其他网络，不等于绕过规则中的 DIRECT | 保留，说明需要重建 VPN |
| IPv6 / `vpn.ipv6` | 条件有效 | 决定 VPN IPv6 地址、路由、DNS 地址及传入 TUN 的 IPv6 信息 | 保留并与另两个 IPv6 设置联动解释 |
| DNS 劫持 / `dnsHijacking` | **明确失效** | 保存、同步、重启提示仍存在，但最终 `VpnOptions.dns` 仅依赖 ipv6 | 移除可操作开关或恢复实际语义，见 F1 |
| 绕过域名 / `bypassDomain` | 条件有效 | 进入 VPN HTTP 代理排除列表；不是通用 TUN / Clash 直连域名规则 | 改说明；HTTP 代理未采用时提示不适用 |
| 可信网络列表 | 有效 | 智能暂停启用且列表非空时使用；当前匹配以非 VPN IPv4 信息为基础 | 保留，补 CIDR 校验和状态说明即可 |
| 协议栈 / `tun.stack` | 条件有效，提示有缺口 | 下次原生 startTun 会使用；运行中 Go updateListeners 在 Android 不重建 TUN，单改 stack 又不触发当前 VPN 提示比较 | 补重建提示和应用流程 |
| 路由模式、路由地址 | **Android 传递断路** | 值进入 Dart Tun / Go 配置，但 sharedState 构造 VpnOptions 未填 routeAddress，使用默认空列表 | 优先修复，见 F2 |

证据：页面入口、Provider、VPN 管理器、原生 Builder、Go Android TUN 封装可互相对应。[^1][^8][^9][^10][^11]

Android 的 `setHttpProxy` 设置的是 **VPN 网络 HTTP 代理**；HTTP 客户端是否遵守代理、关联用户兼容策略、平台版本都会影响观察结果。不能因为部分流量仍走 TUN，就判断该开关没用。`allowBypass` 也不是为指定域名生成 Clash 直连规则。[Android 官方 API](https://developer.android.com/reference/android/net/VpnService.Builder) 支持这两个语义区分。

### F1：DNS 劫持是确证的“保存有效、行为无效”

链路为 `DNSHijackingItem` → `vpnSetting.dnsHijacking` → `sharedState.vpnOptions.dnsHijacking`，前半段完整。最后一段却是 `VpnOptions.dns → tunDnsHijackServers(ipv6)`，完全不读取 `dnsHijacking`。函数固定包含 IPv4 的通配地址和 VPN DNS 地址，IPv6 开启时再加对应 IPv6 地址；Go 将它们转换为 53 端口劫持配置。[^1][^9][^10][^11]

因此，在其他条件相同的情况下，将此开关设为 true / false，甚至重启 VPN，当前代码生成的劫持参数仍相同。默认字段还是 false，界面默认“关闭”尤其容易误导。

**建议优先保留当前已经承担兼容性职责的实际劫持策略，将界面改成只读状态说明。** 如果确实需要提供退出劫持的能力，再定义清楚关闭后是“只接管 VPN DNS 地址”还是“完全不接管 53 端口”，并补真机验证。不要只为了让开关“有反应”就恢复可能破坏现有 DNS 兼容性的旧分支。源码注释中的设备兼容动机是历史解释，本报告未独立复现该历史故障。

### F2：路由设置没有影响 Android Builder 收到的路由

`Tun.getRealTun(routeMode)` 会计算自定义路由或绕过私网地址；但 `sharedStateProvider` 创建 `VpnOptions` 时未传 `routeAddress`。Dart 模型该字段默认 `[]`，Android Builder 遇到空列表则安装默认全局路由。另一方面，Go `updateListeners()` 明确在 Android 跳过 `ReCreateTun()`，不能靠改 Go Tun 字段弥补。[^8][^9][^11][^12]

结论限于 **Android VPN 捕获路由**：不能据此说 Clash 规则分流整体失效。复现验收应检查 Builder / 系统实际路由，而不是仅看生成的 YAML。

最小修复方向为：将计算后的路由传入 VpnOptions，并把路由差异纳入重建 VPN 的判断。当前提示逻辑只比较 VpnProps；只补传值而不补应用时机仍会留下“运行中看似无效”。

## 二、DNS 页面逐项核查

DNS 页面显示的是 APP 自己的 DNS 覆写值，**不保证就是当前内核正在使用的值**。页面没有根据覆写开关统一禁用下级项，也没有展示实际来源。[^2]

| 开关 / 字段 | 判断 | 真实条件与作用 |
|---|---|---|
| 覆写 DNS / `overrideDns` | 条件有效 | 完整合成时决定是否覆盖 APP 拥有的 DNS 字段；原始 DNS 未启用时，即使它关闭也会走 APP DNS 补全 |
| 状态 / `dns.enable` | 条件有效 | 只有 APP DNS 值被选用且完整应用后才改变内核 DNS 启用状态；不能保证始终控制原订阅 DNS |
| 使用 Hosts / `useHosts` | 条件有效 | 完整应用后进入 DNS 处理配置；需有匹配 hosts 才容易观察到差别 |
| 使用系统 Hosts / `useSystemHosts` | 条件有效 | 内核赋给 resolver 的系统 hosts 开关；没有匹配条目时无差异是正常现象 |
| IPv6 / `dns.ipv6` | 条件有效，被基础 IPv6 约束 | 完整合成中基础 IPv6 关闭会强制它关闭；内核构造 DNS 时也结合 general IPv6 |
| 遵守规则 / `respectRules` | 条件有效 | DNS 上游连接使用路由规则；当前内核要求 proxy-server-nameserver 非空，否则配置解析失败 |
| PreferH3 / `preferH3` | 条件有效 | 传入 DNS 上游构造；主要针对适用的 DoH 传输，不是所有 APP 请求都变成 HTTP/3 |
| Fallback GeoIP / `fallbackFilter.geoip` | 条件有效 | 参与 fallback 过滤判断，需实际使用相关 DNS fallback 路径及地理数据 |

其他 DNS 输入项也有合成链路：监听地址、DNS 模式、Fake-IP 范围与过滤、默认 DNS、nameserver-policy、nameserver、fallback、proxy-server-nameserver，以及 fallback-filter 的地区码、geosite、ipcidr、domain。它们都受同样的 **来源优先级和完整应用时机** 约束；Fake-IP 项还依赖模式，fallback 项依赖对应解析路径。[^2][^13][^14]

这些功能在本地内核中仍有实现。官方文档也说明 DNS `respect-rules`、`prefer-h3`、`ipv6` 等有各自适用条件，可辅助编写界面说明；本报告没有把最新版文档当作本地二进制已实现功能的证明。[Mihomo DNS 配置](https://wiki.metacubex.one/config/dns/)

### F3：DNS 覆写的真实优先级

当前合成代码可归纳为：[^13]

| 原始配置 `dns.enable` | 覆写开关 | DNS 主要来源 |
|---|---|---|
| true | false | 保留订阅 / 脚本结果的 DNS；仍受基础 IPv6 和追加系统 DNS 的后处理影响 |
| true | true | APP 覆盖其拥有的 DNS 字段，保留非 APP 拥有的字段 |
| false / 缺失 | false 或 true | 使用 APP DNS 值补全，并向 nameserver 追加 `system://` |

两个直接后果：

- 用户在“覆写关闭、订阅 DNS 已启用”时操作下级开关，这些值可以被保存，但不会替换订阅同名值。
- “追加系统 DNS”关闭，不等于最终没有系统 DNS：原配置可能已经包含它，原始 DNS 未启用的补全路径也会添加它。

这不是八个独立的死开关，而是**一个来源决策没有在界面上表达清楚**。建议显示“当前采用订阅 DNS / APP DNS / 自动补全”，并在不采用 APP 值时明确标注“仅保存为覆写预设”。若选择禁用下级输入，仍须先按真实优先级计算，不能简单照 `overrideDns=false` 一律禁用。

### F4：保存与应用缺少闭环

`CoreManager` 只监听 `updateParamsProvider` 进行热更新；该结构不包含 DNS、overrideDns、appendSystemDns、geodataLoader、hosts、globalUa、非 mixed-port 端口等完整配置字段。`setupStateProvider` 虽然依赖 DNS，但没有因为它变化就自动执行完整应用的对应监听。工具页导航及这些设置页也没有离开时调用 `autoApplyProfile` 的流程。[^3][^7][^8][^13][^15]

因此，在 **已有配置运行、只操作这些页面、没有其他完整应用事件** 的场景中，新值会停留在保存状态。后续完整应用可以消费它们，这与永久失效不同。不要依赖用户偶然切换订阅或重新启动功能才能更新。

建议采用最小且清晰的方式：对需要完整合成的设置保留“待应用”状态，提供统一的应用入口；应用成功后再更新运行中状态。可以选择离页批量应用，但必须捕获验证失败并保留旧运行状态。现有配置提交机制值得复用，无须另建一套内核配置系统。

### F5：三个 IPv6 控制的组合不够清晰

网络 IPv6 控制 **VPN 入站 IPv6 接管**；基本设置 IPv6 控制 **内核通用 IPv6 能力 / 解析约束**；DNS IPv6 控制 **DNS AAAA 应答能力**。三者不是重复开关。当前合成函数名 `alignDnsIpv6WithCore` 读取基础 IPv6，并未检查 `vpn.ipv6`；其注释涉及 TUN，但实际判断并非 TUN 状态。[^9][^13][^14]

还存在应用时机差异：热更新基础 IPv6 只改变 `resolver.DisableIPv6`，完整应用才重建 DNS 相关配置。先按关闭状态完整应用，再运行中开启基础 IPv6，不能假定以前构造的 DNS resolver 已同步重建。

建议先统一解释和状态展示，保持三层语义；如需联动，定义组合矩阵后再做。具体网络是否出现 IPv6 等待或泄漏，必须通过对应设备和真实路由验证，本报告不将其作为已复现事故。

## 三、基本设置逐项核查

| 开关 | 判断 | 最终消费者 / 限制 | 建议 |
|---|---|---|---|
| IPv6 | 有效但有组合 / 时机差异 | Go 热更新 resolver 标志；完整配置参与 DNS 构造 | 见 F5 |
| 允许局域网 | **完整应用有效、热更新缺陷** | 完整 YAML 写入 allow-lan；Go updateConfig 没有更新 General.AllowLan | 优先补齐，见 F6 |
| 统一延迟 | 有效 | Go 设置 `adapter.UnifiedDelay`，影响内核延迟测试语义 | 保留；不承诺所有独立测量都受其控制 |
| 追加系统 DNS | 条件 / 延后有效 | 合成 nameserver 时添加 `system://`；关闭不删除来源中已有项 | 保留，说明“追加”的含义 |
| 查找进程 | 有效 | true 映射 always，false 映射 off，Go 调用 SetFindProcessMode | 保留；关闭并非自动切 strict 模式 |
| TCP 并发 | 有效 | Go 调用 SetTcpConcurrent；作用于适用拨号过程 | 保留，不承诺一定加速 |
| Geodata 加载器 | 条件 / 延后有效 | UI 映射 memconservative / standard；完整解析、应用后用于 geodata loader | 保留或改枚举说明，不需重写 |
| 外部控制器 | 有效，有能力边界 | 映射本地控制器地址 / 空地址，调用 ReCreateServer | 保留；不是 APP 和原生核心之间的总通信开关 |

其他基础项：日志级别和 mixed-port 存在热更新；UA、Hosts、额外 HTTP / SOCKS / redir / tproxy 端口在最终配置中有写入，但主要依赖完整应用。Android 非 root 环境不能仅因显示 redir / tproxy 端口，就承诺系统已自动将流量导入该端口。UA 也有 APP 自己的读取路径，不能把它所有用途都归为延后生效。[^3][^8][^12][^13][^16]

### F6：允许局域网热更新遗漏

UI 更新 `patch.allowLan`；Dart `UpdateParams` 和 Go `UpdateParams` 都有 allow-lan 字段。问题是 Go `updateConfig` 处理了 mixed-port、进程、TCP 并发、统一延迟、模式、日志、IPv6、控制器、Tun 等字段，**未把 params.AllowLan 写入 general.AllowLan**。之后 `updateListeners()` 再从旧的 general.AllowLan 读取，监听行为仍按旧值。[^3][^8][^12]

完整合成会写入 allow-lan，因此不能说它永远无效；但运行中关闭这一开关的实际含义与界面反馈不一致。建议作为优先修复项，并用“另一台局域网设备是否能连接代理端口”验收两个切换方向，不能只验 Provider 或 YAML。

## 四、应用程序页面逐项核查

| 开关 | 判断 | 实际作用 / 触发点 |
|---|---|---|
| 退出时最小化 | 有效 | 返回 / 退出处理在 `system.back()` 与 `handleExit()` 之间分支；关闭后有真实核心销毁路径 |
| 自动运行 | 有效 | 初始化结合原生会话状态决定是否完整启动；不是 Android 开机自启，也不是立刻开始运行 |
| 隐藏最近任务 | 有效 | AndroidManager 监听 hidden，调用原生 updateExcludeFromRecents；初始化也同步 |
| 切页动画 | 有效 | Home 在 animateToPage / jumpToPage 之间选择；不是全局关闭所有动画 |
| 自动关闭连接 | 有效 | 成功切换节点后关闭已有连接；关闭时仍会 reset DNS resolver connection，因此不等于任何连接行为都不发生 |
| 仅统计代理 | 有效，版本敏感 | Flutter / 原生共享统计参数传入 Go；Go 在 ProxyNow / ProxyTotal 与全量统计间选择。只能统计内核可见流量，不是手机所有应用流量 |
| 自动检查更新 | 有效，渠道有限制 | APP 初始化触发检查；地址来自当前 fork 的 releases/latest，不是旧 FlClash 仓库；没有承诺自动跟踪 beta prerelease |

证据见 APP 页、AndroidManager、Home、Action、统计核心、更新 URL。[^4][^5][^6][^17][^18]

**这七项没有发现应当作为死开关删除的证据。** 可改进之处主要是文案：“切页动画”准确限定标签页；“自动运行”明确为 APP 初始化；“自动检查更新”说明当前正式版渠道。如果未来希望 beta 也自动提示，属于渠道能力扩展，不是这一开关完全失效。

仅统计代理已经找到真实统计分支，但当前内核统计分类有未提交改动，不应把本轮源码结论直接写成“线上 APK 代理流量统计已准确验证”。需在指定构建版本上分别产生 DIRECT 与代理流量再验收。

## 五、进阶设置和二级页面

进阶设置目前包含访问控制、全局附加规则、脚本管理。脚本管理是资源管理入口，**存在脚本不等于所有订阅启用了脚本**；订阅自身还需选择相应覆写模式和脚本。标准 / 脚本 / 自定义模式分别走不同配置路径。[^15][^19]

| 控件 | 判断 | 条件 / 生效时机 |
|---|---|---|
| 访问控制启用 / 停用 | 有效 | 修改编辑态，保存后进入 VpnProps，重建 VPN 时决定调用允许 / 排除应用 API |
| 访问控制应用勾选、允许 / 排除模式 | 有效 | 决定 VPN 捕获哪些包；APP 自己有原生特殊处理，不能按普通应用推断 |
| 显示系统应用 | **显示有效，但有策略副作用** | 列表过滤正常；保存会过滤掉不再显示的已选包，见 F7 |
| 显示无网络权限应用 | **显示有效，但有策略副作用** | 与上项共享保存裁剪逻辑 |
| 标准覆写中逐条启用全局规则 | 有效 | 保存 disabled 关联，queryAddedRules 排除相应规则；退出覆写页面触发应用 |
| 全局规则对话框的“源 IP / 不解析”选择卡片 | 有效 | 修改本地布尔值，提交生成 Rule；与自定义规则的空回调控件是两套实现 |
| 自定义规则“不解析域名” | **明确失效** | Switch 的 `onChanged: (_) {}` 为空；父行也未提供切换逻辑 |
| 自定义规则“匹配源 IP” | **明确失效** | 同上；选择支持附加参数的规则类型时可达 |
| 自定义组“隐藏” | 条件有效 | 保存 hidden；当前 rule 模式组列表过滤 hidden，global 模式未用相同过滤 |
| 自定义组“使用时测试 / lazy” | 条件有效 | 写入组参数，需相关自动测试组、完整应用及内核健康检查路径 |
| 自定义组“禁用 UDP” | 条件有效 | 写入 disable-udp，内核组解析支持；不等于全 APP 全局禁 UDP |
| 包含全部代理 / 包含全部代理提供者 | 有效 | 修改组的 include-all-proxies / include-all-providers，保存并完整应用后由内核组解析消费 |

上述“自定义组有效”表示编辑、持久化、合成、内核解析链路存在；没有针对每一种组类型逐个进行真实流量测试。[^19][^20][^21][^22]

### F7：显示过滤与访问控制策略发生耦合

`AccessView._getRealAccessControlProps()` 按当前“显示系统应用 / 显示无网络应用”的过滤条件生成可见包集合，再把 `currentList` 与该集合求交集，最后保存。[^20]

可从代码推导的场景：先显示系统应用并勾选某个系统包，保存；再隐藏系统应用并保存，新列表会移除该包。允许名单和排除名单对应的影响方向不同，但共同点是 **显示动作改变了策略集合**。目前没有真机复现结果，本结论来自明确的集合裁剪实现。

建议让显示过滤只作用于列表视图，保留未显示的已选项；若确实想清理不存在或无效的包，应作为单独的显式操作。验收需覆盖两种模式，不能只测勾选控件。

### F8：自定义规则的两个开关应复用已存在的正确逻辑

`custom/rules.dart` 中两个 Switch 都有外观、当前值和空回调；同页按 `ruleAction.hasParams` 展示，属于真实可达问题。与此同时，全局附加规则对话框已经能修改 `_src` 和 `_noResolve` 并写入 Rule。[^21]

最小修复是补正确状态写入和保存验证；不需要改内核规则引擎。进一步可复用规则参数编辑组件，避免两套 UI 行为分叉，但复用属于可选清理，不应扩大第一轮修复范围。

## 六、其余页面和继承残留

| 项目 | 判断 / 说明 |
|---|---|
| 主题 → 动态颜色 | 有效；应用层监听 ThemeProps，静态 / 动态配色有实际分支，部分主题状态已有测试 |
| 主题 → 文本缩放开关及比例 | 有效；启用取自定义比例，关闭取系统初始比例，最终有上下限约束；不是所有文字都必须同比缩放，局部组件存在独立策略 |
| 主题模式、动态方案、静态预设 | 有效选择项；不是内核设置，改变相应渲染分支即可成立 |
| 开发者模式 | 有效；控制工具页开发入口，开发页可关闭；不是生产网络性能开关 |
| 新建 / 编辑订阅 → 自动更新 | 有效；创建 / 保存写入 profile，更新调度读取 autoUpdate 和周期；不是开启后立即保证每个时间点都完成更新 |
| 健康观察 | 有效且受调度条件约束；setEnabled 保存设置、安排下次调度；等待到期与空闲条件，不能把暂未发请求判为无效 |
| 首页启动 / 停止及模式选择 | 有实际 Action 路径；启动状态与网络页 VPN 接管开关语义不同 |
| 旧首页 VPN / TUN / 系统代理快捷卡片 | 类和枚举仍在，但当前 DashboardView 固定构建新的 Hero 与网络概览，不走旧动态卡片布局；不能把这些遗留控件算作当前首页仍展示 |
| 桌面 TUN、桌面系统代理、macOS 自动 DNS、开机自启、静默启动、快捷键 | 有平台条件隐藏；不属于当前 Android 可见死开关，不建议为“恢复功能”重新引入桌面依赖 |
| `showLabel`、`openLogs`、`showTrayTitle` 等旧字段 | 本次未发现其在当前设置页面中的对应可操作开关。可列为后续模型清理对象，不能仅凭字段存在计入可见缺陷 |

健康观察与手动 GPT / YouTube 检测应继续独立，打开媒体检查页不应自动启动后两者。本轮已有相关缓存、节点集合、冷却及页面测试通过，但未模拟 APP 被系统杀死后调度是否持续运行。[^23][^24][^25][^26]

没有发现需要增加“桌面兼容开关”的理由。对不可达旧控件，优先保持现状或在后续独立清理中删除无用引用，不把它们混入行为修复。

## 七、建议的修改方向与优先级

这里的优先级依据是“用户相信控制已生效，但真实行为不同”带来的影响，不依据改动代码量。

| 优先级 | 工作项 | 最小成果 | 不应扩展的范围 |
|---|---|---|---|
| P1 | 允许局域网热更新遗漏 | 正确应用 true / false，运行态可验证 | 不重写监听器架构 |
| P1 | Android 路由传递 | 真实路由进入 VpnOptions，重建后系统路由符合选择 | 不扩展桌面或其他 ABI |
| P1 | DNS 劫持虚假开关 | 保留当前策略并显示真实状态，或明确设计并实现可关闭语义 | 不为了 UI 一致性破坏已有兼容修复 |
| P1 | 访问控制显示裁剪 | 隐藏显示项不删除已选策略；显式清理独立处理 | 不重做整个应用分流页面 |
| P2 | 自定义规则两空回调 | 可切换、可保存、最终规则字符串正确 | 不改规则引擎 |
| P2 | 完整配置待应用流程 | DNS / 加载器等保存与应用状态可见，失败不伪装成功 | 复用现有提交事务 |
| P2 | VPN 变更提示覆盖 | stack、路由、bypassDomain、代理端口等对实际实例有影响的参数都能提示重建 | 不对仅显示过滤变化无差别重启 |
| P2 | DNS 来源和 IPv6 说明 | 当前值、期望值、来源、阻断条件可解释 | 不先新增更多细粒度开关 |
| P3 | 文案与遗留代码清理 | 系统代理、自动运行、仅统计代理、更新渠道的含义准确 | 不把“继承代码”本身当成缺陷 |

**推荐分两批落地。** 第一批只处理 F1、F2、F6、F7、F8 这些具体断路 / 副作用，再补针对性验收。第二批整理保存与应用状态、DNS 来源和 VPN 变更提示。若第一批完成后体验已足够清楚，第二批可以只做必要文案与状态，不必引入复杂的新设置框架。

可选的长期约束是为每类设置记录简单契约：保存字段、消费者、需要热更新 / 完整应用 / 重建 VPN、前置条件、验证方式。它可以先是一张开发文档表，不必立即变成运行时注册系统。

## 八、后续验收方案

验收应同时记录：保存值、生成配置、原生接收参数、运行实例版本和外部行为。只看其中一项不能闭环。

| 场景 | 操作 | 合格判据 |
|---|---|---|
| DNS 劫持 | 同一配置分别开 / 关后重建；或交付只读策略状态 | 有开关时参数和实际行为按契约改变；只读时不再声称可关闭 |
| 局域网访问 | 同一 VPN 会话 true→false→true | 另一台 LAN 设备新建代理连接能力随之改变；记录实际监听地址 |
| Android 路由 | 全局 / 绕过私网 / 自定义 CIDR | 原生接收路由和系统安装路由对应；私网目标捕获路径符合设计 |
| 协议栈 | 运行中修改，再执行提示动作 | 提示明确；重建后的 startTun 参数正确，切换前不伪装已应用 |
| DNS 来源 | 原始 DNS 启用 / 禁用 × 覆写开 / 关 | 四种结果符合已批准的优先级，不静默把预设当运行值 |
| 系统 DNS | 原始配置有 / 无 system://，追加开 / 关 | 区分“APP 追加”与“源文件已有”；关闭语义明确 |
| IPv6 | VPN / 基础 / DNS 共 8 种组合 | 分别记录路由、最终 dns.ipv6、AAAA 和连接结果；明确不支持组合 |
| 自定义规则 | 两参数逐项切换、保存、重进 | UI 值、Rule、最终规则字符串一致；适用类型正确 |
| 访问控制显示过滤 | 两模式中选系统包，再隐藏后保存 | 原有策略保留；仅列表显示改变 |
| 仅统计代理 | 指定构建产生 DIRECT 与代理流量 | proxy-only / 全量统计口径一致，通知与页面同源 |
| 健康观察 | 开 / 关并等待调度条件 | 只触发 health；关闭后不安排新轮次；保留冷却约束 |
| 应用失败 | 使用无法解析的 DNS 条件或输入 | 明确显示失败 / 待应用，运行配置不被误报为新值 |

测试构建应沿用项目隔离包名，不覆盖日用版本；真实生产体验判断需记录实际 APK 版本。本报告没有通过本地 release 构建或真实网络压测来补造证据。

## 九、本轮验证结果

执行了以下已有测试集合，未新增测试或修改测试代码：

```text
flutter test --no-pub
  test/mihomo/runtime_config_ownership_test.dart
  test/mihomo/runtime_config_regression_test.dart
  test/providers/smart_auto_stop_test.dart
  test/providers/config_test.dart
  test/startup_attachment_test.dart
  test/theme/static_theme_test.dart
  test/views/profiles/media_check_test.dart
  --reporter expanded
```

**105 项通过，3 项跳过，命令退出码 0。** 上面换行仅用于展示，实际以一条命令运行。

跳过项来自现有 regression 测试：一项因主机 Flutter 测试没有原生 QuickJS；两项是对 Mihomo 类型化归一化丢弃未知字段的已有占位检查。它们不能算作已经验证；本次也没有因此判定脚本运行完整可靠。[^27]

通过项支持的结论包括：DNS 来源和 owned 字段覆盖、未接管字段保留、基础 IPv6 强制 DNS IPv6 关闭、系统 DNS 追加、配置 Provider 组合、启动附着、智能暂停辅助逻辑、主题映射、媒体缓存 / 冷却和节点集合等。

通过项**不证明** Android 路由已接线、allow-lan 热更新正确、每个 UI 控件都能改变真实网络。现有测试主要覆盖合成或辅助逻辑，恰好能解释为什么部分断路长期没有被发现。后续应补“UI / 状态 → 原生参数 / 运行消费者”的薄层测试，以及少量决定性的真机行为验证。

## 来源与定位

以下路径均为本地核查的第一手源码；行号是报告生成时的定位。引用涉及的行为可能跨同文件多个方法，链接为主要入口。网上资料访问于 2026-09-10，仅作语义补充。

[^1]: [网络页面](<D:/Code/Clash myself/FlClash-dev/lib/views/config/network.dart:9>)，VPN、系统代理、绕过、IPv6、DNS 劫持、路由、智能暂停及平台条件。
[^2]: [DNS 页面](<D:/Code/Clash myself/FlClash-dev/lib/views/config/dns.dart:8>)，8 个开关及 DnsOptions / FallbackFilterOptions。
[^3]: [基本设置](<D:/Code/Clash myself/FlClash-dev/lib/views/config/general.dart:239>)，基础开关、字段映射与 generalItems。
[^4]: [应用设置](<D:/Code/Clash myself/FlClash-dev/lib/views/application_setting.dart:223>)，Android 可见项与平台隐藏项。
[^5]: [APP 行为 Action](<D:/Code/Clash myself/FlClash-dev/lib/providers/action.dart:2365>)，返回 / 退出；同文件 initStatus、autoCheckUpdate、节点切换成功处理。
[^6]: [Go 统计入口](<D:/Code/Clash myself/FlClash-dev/core/hub.go:291>)，proxy-only 分支；同文件 closeConnections / handleResetConnections。
[^7]: [偏好保存监听](<D:/Code/Clash myself/FlClash-dev/lib/manager/app_manager.dart:36>)；[配置组合与恢复](<D:/Code/Clash myself/FlClash-dev/lib/providers/config.dart:101>)；[保存实现](<D:/Code/Clash myself/FlClash-dev/lib/providers/action.dart:2427>)。
[^8]: [热更新字段](<D:/Code/Clash myself/FlClash-dev/lib/providers/state.dart:73>)；[热更新监听](<D:/Code/Clash myself/FlClash-dev/lib/manager/core_manager.dart:109>)；[VPN 变更提示](<D:/Code/Clash myself/FlClash-dev/lib/manager/vpn_manager.dart:23>)。
[^9]: [SharedState / VpnOptions 构造](<D:/Code/Clash myself/FlClash-dev/lib/providers/state.dart:518>)；[VpnOptions 默认路由](<D:/Code/Clash myself/FlClash-dev/lib/models/core.dart:41>)；[Android 状态同步](<D:/Code/Clash myself/FlClash-dev/lib/manager/android_manager.dart:25>)。
[^10]: [Android VPN DNS getter](<D:/Code/Clash myself/FlClash-dev/android/service/src/main/java/com/follow/clash/service/VpnService.kt:259>)；[固定 DNS 劫持及 HTTP 代理策略](<D:/Code/Clash myself/FlClash-dev/android/service/src/main/java/com/follow/clash/service/models/VpnOptions.kt:40>)。
[^11]: [Android VPN Builder](<D:/Code/Clash myself/FlClash-dev/android/service/src/main/java/com/follow/clash/service/VpnService.kt:292>)；[Go Android TUN 构造](<D:/Code/Clash myself/FlClash-dev/core/tun/tun.go:18>)；[原生 VPN / 非 VPN 路径](<D:/Code/Clash myself/FlClash-dev/android/service/src/main/java/com/follow/clash/service/RemoteService.kt:686>)。
[^12]: [Go 热更新字段消费](<D:/Code/Clash myself/FlClash-dev/core/common.go:179>)；[监听器与 Android 排除分支](<D:/Code/Clash myself/FlClash-dev/core/common.go:93>)；[Tun 路由计算](<D:/Code/Clash myself/FlClash-dev/lib/models/clash_config.dart:231>)。
[^13]: [最终配置合成](<D:/Code/Clash myself/FlClash-dev/lib/common/task.dart:94>)；[DNS 字段所有权与 IPv6 对齐](<D:/Code/Clash myself/FlClash-dev/lib/services/mihomo_config/runtime_config_patch.dart:81>)。
[^14]: [本地 Mihomo DNS 配置解析](<D:/Code/Clash myself/FlClash-dev/core/Clash.Meta/config/config.go:1408>)；[DNS 应用](<D:/Code/Clash myself/FlClash-dev/core/Clash.Meta/hub/executor/executor.go:238>)；[DNS resolver 构造](<D:/Code/Clash myself/FlClash-dev/core/Clash.Meta/dns/resolver.go:477>)。
[^15]: [工具页导航](<D:/Code/Clash myself/FlClash-dev/lib/views/tools.dart:166>)；[showExtend](<D:/Code/Clash myself/FlClash-dev/lib/widgets/sheet.dart:101>)；[完整 getProfile 链路](<D:/Code/Clash myself/FlClash-dev/lib/providers/action.dart:1574>)；[setupState](<D:/Code/Clash myself/FlClash-dev/lib/providers/state.dart:712>)。
[^16]: [本地内核进程查找分支](<D:/Code/Clash myself/FlClash-dev/core/Clash.Meta/tunnel/tunnel.go:393>)；[Geodata 加载器应用](<D:/Code/Clash myself/FlClash-dev/core/Clash.Meta/hub/executor/executor.go:421>)；[APP UA 读取](<D:/Code/Clash myself/FlClash-dev/lib/state.dart:85>)。
[^17]: [切页动画消费](<D:/Code/Clash myself/FlClash-dev/lib/pages/home.dart:213>)；[成功切换节点后的连接处理](<D:/Code/Clash myself/FlClash-dev/lib/providers/action.dart:3554>)。
[^18]: [更新 Action](<D:/Code/Clash myself/FlClash-dev/lib/providers/action.dart:397>)；[更新地址](<D:/Code/Clash myself/FlClash-dev/lib/common/update.dart:6>)；[当前 fork 常量](<D:/Code/Clash myself/FlClash-dev/lib/common/constant.dart:54>)；[请求实现](<D:/Code/Clash myself/FlClash-dev/lib/common/request.dart:91>)。
[^19]: [进阶页面](<D:/Code/Clash myself/FlClash-dev/lib/views/config/advanced.dart:10>)；[覆写模式与离页应用](<D:/Code/Clash myself/FlClash-dev/lib/views/profiles/overwrite/overwrite.dart:60>)；[全局规则启用 UI](<D:/Code/Clash myself/FlClash-dev/lib/views/profiles/overwrite/standard.dart:271>)；[规则过滤查询](<D:/Code/Clash myself/FlClash-dev/lib/database/rules.dart:57>)。
[^20]: [访问控制保存裁剪](<D:/Code/Clash myself/FlClash-dev/lib/views/access.dart:161>)；[显示过滤选择](<D:/Code/Clash myself/FlClash-dev/lib/views/access.dart:664>)。
[^21]: [自定义规则空回调](<D:/Code/Clash myself/FlClash-dev/lib/views/profiles/overwrite/custom/rules.dart:600>)；[正常规则参数对话框](<D:/Code/Clash myself/FlClash-dev/lib/features/overwrite/rule.dart:190>)。
[^22]: [自定义组开关](<D:/Code/Clash myself/FlClash-dev/lib/views/profiles/overwrite/custom/groups.dart:708>)；[全部代理](<D:/Code/Clash myself/FlClash-dev/lib/views/profiles/overwrite/custom/proxies.dart:193>)；[全部提供者](<D:/Code/Clash myself/FlClash-dev/lib/views/profiles/overwrite/custom/proxy_providers.dart:189>)；[内核组参数](<D:/Code/Clash myself/FlClash-dev/core/Clash.Meta/adapter/outboundgroup/parser.go:35>)；[hidden 消费](<D:/Code/Clash myself/FlClash-dev/lib/providers/state.dart:19>)。
[^23]: [主题页面](<D:/Code/Clash myself/FlClash-dev/lib/views/theme.dart:333>)；[应用层监听主题](<D:/Code/Clash myself/FlClash-dev/lib/application.dart:221>)；[文本缩放](<D:/Code/Clash myself/FlClash-dev/lib/manager/theme_manager.dart:80>)；[开发者开关](<D:/Code/Clash myself/FlClash-dev/lib/views/developer.dart:95>)。
[^24]: [订阅自动更新 UI](<D:/Code/Clash myself/FlClash-dev/lib/views/profiles/edit.dart:106>)；[自动更新候选逻辑](<D:/Code/Clash myself/FlClash-dev/lib/providers/action.dart:54>)；[健康观察启用](<D:/Code/Clash myself/FlClash-dev/lib/providers/health_observation.dart:679>)；[健康观察空闲条件](<D:/Code/Clash myself/FlClash-dev/lib/providers/health_observation.dart:332>)。
[^25]: [当前首页固定布局](<D:/Code/Clash myself/FlClash-dev/lib/views/dashboard/dashboard.dart:10>)；[旧快捷控件平台定义](<D:/Code/Clash myself/FlClash-dev/lib/enum/enum.dart:298>)。
[^26]: [智能暂停配置变更](<D:/Code/Clash myself/FlClash-dev/lib/providers/smart_auto_stop.dart:135>)；[可信网络判断](<D:/Code/Clash myself/FlClash-dev/lib/providers/smart_auto_stop.dart:250>)；[原生智能暂停策略](<D:/Code/Clash myself/FlClash-dev/android/service/src/main/java/com/follow/clash/service/SmartPausePolicy.kt:153>)。
[^27]: [DNS / TUN 所有权测试](<D:/Code/Clash myself/FlClash-dev/test/mihomo/runtime_config_ownership_test.dart:240>)；[合成 regression 测试及跳过说明](<D:/Code/Clash myself/FlClash-dev/test/mihomo/runtime_config_regression_test.dart:305>)；[媒体检查测试](<D:/Code/Clash myself/FlClash-dev/test/views/profiles/media_check_test.dart:1>)。
