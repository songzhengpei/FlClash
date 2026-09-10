package com.follow.clash.service.models

import android.os.Parcelable
import com.follow.clash.common.AccessControlMode
import kotlinx.parcelize.Parcelize
import java.net.InetAddress

@Parcelize
data class AccessControlProps(
    val enable: Boolean,
    val mode: AccessControlMode,
    val acceptList: List<String>,
    val rejectList: List<String>,
) : Parcelable

@Parcelize
data class VpnOptions(
    val enable: Boolean,
    val port: Int,
    val ipv6: Boolean,
    val dnsHijacking: Boolean,
    val accessControlProps: AccessControlProps,
    val allowBypass: Boolean,
    val systemProxy: Boolean,
    val bypassDomain: List<String>,
    val stack: String,
    val routeAddress: List<String>,
) : Parcelable

data class CIDR(val address: InetAddress, val prefixLength: Int)

const val TUN_DNS_V4 = "172.19.0.2"
const val TUN_DNS_V6 = "fdfe:dcba:9876::2"
const val TUN_DNS_ANY_V4 = "0.0.0.0"
const val TUN_DNS_ANY_V6 = "::"

/// Always hijack UDP/53 on TUN, not only the VPN DNS address.
/// Xiaomi SmartDns and Private DNS ignore VpnService addDnsServer and query
/// other resolvers through the tunnel; without 0.0.0.0:53 those lookups
/// black-hole for several seconds after connect.
fun tunDnsHijackServers(ipv6: Boolean): String {
    val parts = mutableListOf(TUN_DNS_ANY_V4, TUN_DNS_V4)
    if (ipv6) {
        parts += TUN_DNS_ANY_V6
        parts += TUN_DNS_V6
    }
    return parts.joinToString(",")
}

/// Decide whether VpnService may publish `127.0.0.1` as the VPN HTTP proxy.
///
/// [android.net.VpnService.Builder.setHttpProxy] attaches one ProxyInfo to
/// every UID on the VPN. Associated users such as Xiaomi XSpace, clone apps,
/// and work profiles can receive `127.0.0.1:mixed-port` without being able to
/// connect to the owner user's loopback, so OkHttp / WebView / XWeb hang in
/// SYN_SENT. TUN already intercepts their traffic. Keep the requested proxy on
/// ordinary single-user devices and fall back to TUN-only capture only when an
/// associated profile is present.
fun shouldAttachVpnHttpProxy(
    systemProxyRequested: Boolean,
    hasAssociatedProfiles: Boolean,
): Boolean = systemProxyRequested && !hasAssociatedProfiles

fun VpnOptions.getIpv4RouteAddress(): List<CIDR> =
    routeAddress.map { it.toCIDR() }.filter { it.address.address.size == 4 }

fun VpnOptions.getIpv6RouteAddress(): List<CIDR> =
    routeAddress.map { it.toCIDR() }.filter { it.address.address.size == 16 }

fun String.isIpv4(): Boolean = toCIDR().address.address.size == 4
fun String.isIpv6(): Boolean = toCIDR().address.address.size == 16

fun String.toCIDR(): CIDR {
    val parts = trim().split("/")
    require(parts.size == 2) { "Invalid CIDR format" }
    val literal = parts[0]
    require(literal.matches(Regex("[0-9a-fA-F:.]+")) &&
        (literal.contains(':') || literal.count { it == '.' } == 3)) {
        "Route must contain an IP literal"
    }
    val prefix = parts[1].toIntOrNull() ?: throw IllegalArgumentException("Invalid prefix length")
    val address = InetAddress.getByName(literal)
    require(prefix in 0..(address.address.size * 8)) { "Invalid prefix length for IP version" }
    return CIDR(address, prefix)
}
