#!/usr/bin/env bats
# tests/vpn.bats - lib/vpn.sh: endpoint parsing and kill-switch bootstrap rules.

load 'test_helper'

setup() {
    load_libs
    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

_write() { printf '%s\n' "$2" > "${TMPDIR_TEST}/$1"; }

@test "parse: openvpn remote line with explicit port and proto" {
    _write client.ovpn "client
dev tun
proto udp
remote vpn.example.com 1195 udp
resolv-retry infinite"
    run _parse_vpn_endpoint "${TMPDIR_TEST}/client.ovpn"
    [ "$status" -eq 0 ]
    [ "$output" = "vpn.example.com 1195 udp" ]
}

@test "parse: openvpn defaults port to 1194 and proto from proto line" {
    _write c.ovpn "client
dev tun
proto tcp
remote 203.0.113.5"
    run _parse_vpn_endpoint "${TMPDIR_TEST}/c.ovpn"
    [ "$status" -eq 0 ]
    [ "$output" = "203.0.113.5 1194 tcp" ]
}

@test "parse: openvpn normalizes tcp-client to tcp" {
    _write c.ovpn "client
remote host.tld 443 tcp-client"
    run _parse_vpn_endpoint "${TMPDIR_TEST}/c.ovpn"
    [ "$status" -eq 0 ]
    [ "$output" = "host.tld 443 tcp" ]
}

@test "parse: wireguard endpoint, proto is always udp" {
    _write wg0.conf "[Interface]
PrivateKey = abc
Address = 10.0.0.2/32

[Peer]
PublicKey = def
Endpoint = 198.51.100.10:51820
AllowedIPs = 0.0.0.0/0"
    run _parse_vpn_endpoint "${TMPDIR_TEST}/wg0.conf"
    [ "$status" -eq 0 ]
    [ "$output" = "198.51.100.10 51820 udp" ]
}

@test "parse: fails when no endpoint is present" {
    _write empty.ovpn "client
dev tun"
    run _parse_vpn_endpoint "${TMPDIR_TEST}/empty.ovpn"
    [ "$status" -ne 0 ]
}

@test "bootstrap-rules: emits a server ACCEPT rule per IP plus DNS" {
    run _killswitch_bootstrap_rules 1194 udp 203.0.113.5 203.0.113.6
    [ "$status" -eq 0 ]
    [[ "$output" == *"-d 203.0.113.5 -p udp --dport 1194 -j ACCEPT"* ]]
    [[ "$output" == *"-d 203.0.113.6 -p udp --dport 1194 -j ACCEPT"* ]]
    [[ "$output" == *"-p udp --dport 53 -j ACCEPT"* ]]
    [[ "$output" == *"-p tcp --dport 53 -j ACCEPT"* ]]
}

@test "bootstrap-rules: still emits DNS rules when no server IP is known" {
    run _killswitch_bootstrap_rules 1194 udp
    [ "$status" -eq 0 ]
    [[ "$output" == *"--dport 53 -j ACCEPT"* ]]
}
