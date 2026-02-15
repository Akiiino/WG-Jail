#!/usr/bin/env bash
# test-parser.sh — Test suite for parse-wg-quick.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${SCRIPT_DIR}/parse-wg-quick.sh"
TEST_DIR="${SCRIPT_DIR}/tests"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

PASS=0
FAIL=0
TOTAL=0

# ── Helpers ────────────────────────────────────────────────────────────

red()   { printf '\033[1;31m%s\033[0m' "$*"; }
green() { printf '\033[1;32m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

assert_exit() {
    local desc="$1" expected_exit="$2" config="$3"
    TOTAL=$((TOTAL + 1))
    local outdir="${WORK_DIR}/out_${TOTAL}"
    local actual_exit=0
    bash "${PARSER}" "${config}" "${outdir}" >/dev/null 2>&1 || actual_exit=$?
    if [[ "${actual_exit}" -eq "${expected_exit}" ]]; then
        PASS=$((PASS + 1))
        echo "  $(green PASS)  ${desc}"
    else
        FAIL=$((FAIL + 1))
        echo "  $(red FAIL)  ${desc} (expected exit ${expected_exit}, got ${actual_exit})"
    fi
}

assert_file_contains() {
    local desc="$1" file="$2" expected="$3"
    TOTAL=$((TOTAL + 1))
    if [[ ! -f "${file}" ]]; then
        FAIL=$((FAIL + 1))
        echo "  $(red FAIL)  ${desc} (file '${file}' does not exist)"
        return
    fi
    if grep -qF "${expected}" "${file}"; then
        PASS=$((PASS + 1))
        echo "  $(green PASS)  ${desc}"
    else
        FAIL=$((FAIL + 1))
        echo "  $(red FAIL)  ${desc} (expected '${expected}' in ${file##*/})"
        echo "         actual contents: $(cat "${file}")"
    fi
}

assert_file_not_contains() {
    local desc="$1" file="$2" unexpected="$3"
    TOTAL=$((TOTAL + 1))
    if [[ ! -f "${file}" ]]; then
        # File doesn't exist — it certainly doesn't contain the string
        PASS=$((PASS + 1))
        echo "  $(green PASS)  ${desc}"
        return
    fi
    if ! grep -qF "${unexpected}" "${file}"; then
        PASS=$((PASS + 1))
        echo "  $(green PASS)  ${desc}"
    else
        FAIL=$((FAIL + 1))
        echo "  $(red FAIL)  ${desc} (found '${unexpected}' in ${file##*/} but shouldn't)"
    fi
}

assert_file_line_count() {
    local desc="$1" file="$2" expected_count="$3"
    TOTAL=$((TOTAL + 1))
    if [[ ! -f "${file}" ]]; then
        FAIL=$((FAIL + 1))
        echo "  $(red FAIL)  ${desc} (file does not exist)"
        return
    fi
    local actual_count
    actual_count=$(wc -l < "${file}")
    if [[ "${actual_count}" -eq "${expected_count}" ]]; then
        PASS=$((PASS + 1))
        echo "  $(green PASS)  ${desc}"
    else
        FAIL=$((FAIL + 1))
        echo "  $(red FAIL)  ${desc} (expected ${expected_count} lines, got ${actual_count})"
    fi
}

run_parser() {
    local config="$1" outdir="$2"
    bash "${PARSER}" "${config}" "${outdir}" 2>/dev/null
}

# ── Test 1: Standard config ───────────────────────────────────────────

echo ""
echo "$(bold '━━━ Test 1: Standard Mullvad-style config ━━━')"
OUT="${WORK_DIR}/01"
run_parser "${TEST_DIR}/01-standard.conf" "${OUT}"

assert_file_contains   "addresses: has IPv4"              "${OUT}/addresses"  "10.64.186.60/32"
assert_file_contains   "addresses: has IPv6"              "${OUT}/addresses"  "fc00:bbbb:bbbb:bb01::2:ba3a/128"
assert_file_line_count "addresses: exactly 2"             "${OUT}/addresses"  2
assert_file_contains   "dns: has 10.64.0.1"               "${OUT}/dns"       "10.64.0.1"
assert_file_line_count "dns: exactly 1"                   "${OUT}/dns"       1
assert_file_contains   "endpoints: has endpoint"           "${OUT}/endpoints" "185.65.135.176:51820"
assert_file_contains   "wg.conf: has PrivateKey"           "${OUT}/wg.conf"   "PrivateKey"
assert_file_contains   "wg.conf: has PublicKey"            "${OUT}/wg.conf"   "PublicKey"
assert_file_contains   "wg.conf: has AllowedIPs"           "${OUT}/wg.conf"   "AllowedIPs"
assert_file_not_contains "wg.conf: no Address"             "${OUT}/wg.conf"   "Address"
assert_file_not_contains "wg.conf: no DNS"                 "${OUT}/wg.conf"   "DNS"

# Verify the stripped config is valid for wg setconf (has [Interface] and [Peer])
assert_file_contains   "wg.conf: has [Interface]"          "${OUT}/wg.conf"   "[Interface]"
assert_file_contains   "wg.conf: has [Peer]"               "${OUT}/wg.conf"   "[Peer]"

# ── Test 2: Full-featured config ──────────────────────────────────────

echo ""
echo "$(bold '━━━ Test 2: Full-featured config with all wg-quick directives ━━━')"
OUT="${WORK_DIR}/02"
run_parser "${TEST_DIR}/02-full-featured.conf" "${OUT}"

assert_file_line_count "addresses: 2 (one per Address line)"  "${OUT}/addresses"  2
assert_file_contains   "addresses: has fd00::2/128"        "${OUT}/addresses"  "fd00::2/128"
assert_file_line_count "dns: 3 (2 from first DNS, 1 from second)" "${OUT}/dns" 3
assert_file_contains   "dns: has 1.1.1.1"                 "${OUT}/dns"       "1.1.1.1"
assert_file_contains   "dns: has 9.9.9.9"                 "${OUT}/dns"       "9.9.9.9"
assert_file_contains   "dns: has 8.8.8.8"                 "${OUT}/dns"       "8.8.8.8"
assert_file_contains   "mtu: has 1380"                    "${OUT}/mtu"       "1380"

# All wg-quick directives must be stripped
assert_file_not_contains "wg.conf: no Address"             "${OUT}/wg.conf"   "Address"
assert_file_not_contains "wg.conf: no DNS"                 "${OUT}/wg.conf"   "DNS"
assert_file_not_contains "wg.conf: no MTU"                 "${OUT}/wg.conf"   "MTU"
assert_file_not_contains "wg.conf: no Table"               "${OUT}/wg.conf"   "Table"
assert_file_not_contains "wg.conf: no SaveConfig"          "${OUT}/wg.conf"   "SaveConfig"
assert_file_not_contains "wg.conf: no PreUp"               "${OUT}/wg.conf"   "PreUp"
assert_file_not_contains "wg.conf: no PostUp"              "${OUT}/wg.conf"   "PostUp"
assert_file_not_contains "wg.conf: no PreDown"             "${OUT}/wg.conf"   "PreDown"
assert_file_not_contains "wg.conf: no PostDown"            "${OUT}/wg.conf"   "PostDown"

# But wg-native fields must survive, including through whitespace normalization
assert_file_contains   "wg.conf: has PrivateKey"           "${OUT}/wg.conf"   "PrivateKey"
assert_file_contains   "wg.conf: has ListenPort"           "${OUT}/wg.conf"   "ListenPort"
assert_file_contains   "wg.conf: has PresharedKey"         "${OUT}/wg.conf"   "PresharedKey"
assert_file_contains   "wg.conf: has PersistentKeepalive"  "${OUT}/wg.conf"   "PersistentKeepalive"

# Comments should be stripped from PresharedKey value
assert_file_not_contains "wg.conf: no trailing comment"    "${OUT}/wg.conf"   "trailing comment"

# ── Test 3: Multiple peers with tricky base64 keys ───────────────────

echo ""
echo "$(bold '━━━ Test 3: Multiple peers, base64 keys with == ━━━')"
OUT="${WORK_DIR}/03"
run_parser "${TEST_DIR}/03-multi-peer.conf" "${OUT}"

assert_file_line_count "endpoints: 3 endpoints"           "${OUT}/endpoints" 3
assert_file_contains   "endpoints: has IPv4"               "${OUT}/endpoints" "192.168.1.1:51820"
assert_file_contains   "endpoints: has IPv6 bracket"       "${OUT}/endpoints" "[2001:db8::1]:51820"
assert_file_contains   "endpoints: has hostname"           "${OUT}/endpoints" "vpn3.example.com:443"

# Keys with == must survive intact
assert_file_contains   "wg.conf: key with =="              "${OUT}/wg.conf"   "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=="
assert_file_contains   "wg.conf: preshared key with =="    "${OUT}/wg.conf"   "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=="

# Should have 3 [Peer] sections
PEER_COUNT=$(grep -c '^\[Peer\]' "${OUT}/wg.conf")
TOTAL=$((TOTAL + 1))
if [[ "${PEER_COUNT}" -eq 3 ]]; then
    PASS=$((PASS + 1))
    echo "  $(green PASS)  wg.conf: has 3 [Peer] sections"
else
    FAIL=$((FAIL + 1))
    echo "  $(red FAIL)  wg.conf: expected 3 [Peer] sections, got ${PEER_COUNT}"
fi

# ── Test 4: grep+source trap config ──────────────────────────────────

echo ""
echo "$(bold '━━━ Test 4: Config that would break grep|source ━━━')"
OUT="${WORK_DIR}/04"
run_parser "${TEST_DIR}/04-grep-traps.conf" "${OUT}"

# PostUp containing "DNS Address Endpoint $(whoami)" must be stripped
assert_file_not_contains "wg.conf: no PostUp"              "${OUT}/wg.conf"   "PostUp"
assert_file_not_contains "wg.conf: no whoami"              "${OUT}/wg.conf"   "whoami"
assert_file_not_contains "wg.conf: no shell expansion"     "${OUT}/wg.conf"   '$('

# The actual DNS and Address should be correctly extracted
assert_file_contains   "dns: correct DNS extracted"        "${OUT}/dns"       "10.64.0.1"
assert_file_line_count "dns: only 1 DNS (not from PostUp)" "${OUT}/dns"       1
assert_file_contains   "addresses: correct address"        "${OUT}/addresses" "10.0.0.2/24"
assert_file_line_count "addresses: only 1 (not from PostUp)" "${OUT}/addresses" 1

# ── Test 5: Missing DNS — must fail ──────────────────────────────────

echo ""
echo "$(bold '━━━ Test 5: Missing DNS — should fail validation ━━━')"
assert_exit "rejects config without DNS"  3  "${TEST_DIR}/05-no-dns.conf"

# ── Test 6: Missing [Interface] — must fail ──────────────────────────

echo ""
echo "$(bold '━━━ Test 6: Missing [Interface] — should fail validation ━━━')"
assert_exit "rejects config without [Interface]"  3  "${TEST_DIR}/06-no-interface.conf"

# ── Test 7: Minimal config ───────────────────────────────────────────

echo ""
echo "$(bold '━━━ Test 7: Minimal valid config ━━━')"
OUT="${WORK_DIR}/07"
run_parser "${TEST_DIR}/07-minimal.conf" "${OUT}"

assert_file_contains   "wg.conf: has PrivateKey"           "${OUT}/wg.conf"   "PrivateKey"
assert_file_line_count "addresses: 1"                      "${OUT}/addresses" 1
assert_file_line_count "dns: 1"                            "${OUT}/dns"       1
# No endpoint specified for this peer — file should be empty
assert_file_line_count "endpoints: 0 (none specified)"     "${OUT}/endpoints" 0

# ── Test 8: Unknown section — must fail ──────────────────────────────

echo ""
echo "$(bold '━━━ Test 8: Unknown section header — should fail parse ━━━')"
assert_exit "rejects unknown [Server] section"  2  "${TEST_DIR}/08-unknown-section.conf"

# ── Test 9: Nonexistent file — must fail ─────────────────────────────

echo ""
echo "$(bold '━━━ Test 9: Nonexistent file ━━━')"
assert_exit "rejects nonexistent file"  1  "/nonexistent/path/wg0.conf"

# ── Test 10: Verify wg.conf is actually usable by wg ─────────────────

echo ""
echo "$(bold '━━━ Test 10: Stripped config structural validity ━━━')"
OUT="${WORK_DIR}/01"  # reuse standard config output

# The stripped config should:
# - Start with [Interface] (possibly after blank lines)
# - Have Key = Value lines
# - Not have any wg-quick-only keys
# - Be parseable by checking it only has known wg keys

TOTAL=$((TOTAL + 1))
KNOWN_WG_KEYS="PrivateKey|ListenPort|FwMark|PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive"
BAD_KEYS=0
while IFS= read -r line; do
    # Skip empty lines, comments, section headers
    [[ -z "${line}" || "${line}" == "["* ]] && continue
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    if ! [[ "${key}" =~ ^(${KNOWN_WG_KEYS})$ ]]; then
        echo "         unexpected key in wg.conf: '${key}'"
        BAD_KEYS=$((BAD_KEYS + 1))
    fi
done < "${OUT}/wg.conf"

if [[ ${BAD_KEYS} -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  $(green PASS)  wg.conf contains only valid wg(8) keys"
else
    FAIL=$((FAIL + 1))
    echo "  $(red FAIL)  wg.conf contains ${BAD_KEYS} unexpected key(s)"
fi

# ── Summary ───────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${FAIL} -eq 0 ]]; then
    echo "$(green "All ${TOTAL} tests passed.")"
else
    echo "$(red "${FAIL} of ${TOTAL} tests failed.")"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit "${FAIL}"
