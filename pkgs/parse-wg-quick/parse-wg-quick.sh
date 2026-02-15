#!/usr/bin/env bash
# parse-wg-quick.sh — Safe parser for wg-quick configuration files.
#
# Extracts wg-quick-specific metadata into individual files and produces
# a stripped config suitable for `wg setconf`.
#
# Usage: parse-wg-quick.sh <config-file> <output-dir>
#
# Output files in <output-dir>:
#   wg.conf    — Stripped config for `wg setconf` (no wg-quick directives)
#   addresses  — One IP/CIDR per line (from Address fields)
#   dns        — One DNS server IP per line (from DNS fields)
#   endpoints  — One endpoint (host:port) per line (from Endpoint fields)
#   mtu        — MTU value, if specified
#
# Exit codes:
#   0 — Success
#   1 — Usage error or file not found
#   2 — Parse error (malformed config)
#   3 — Validation error (e.g., missing DNS)
#
# Security: This script never uses `source`, `eval`, or any form of
# dynamic code execution on the config file contents.

set -euo pipefail

readonly PROG="${0##*/}"

die() {
    echo "${PROG}: error: $*" >&2
    exit 1
}

die_parse() {
    echo "${PROG}: parse error (line ${LINE_NUM}): $*" >&2
    exit 2
}

die_validate() {
    echo "${PROG}: validation error: $*" >&2
    exit 3
}

usage() {
    echo "Usage: ${PROG} <config-file> <output-dir>" >&2
    exit 1
}

# ── Argument handling ──────────────────────────────────────────────────

[[ $# -eq 2 ]] || usage

CONFIG_FILE="$1"
OUTPUT_DIR="$2"

[[ -f "${CONFIG_FILE}" ]] || die "config file '${CONFIG_FILE}' does not exist"
[[ -r "${CONFIG_FILE}" ]] || die "config file '${CONFIG_FILE}' is not readable"

mkdir -p "${OUTPUT_DIR}"

# ── State ──────────────────────────────────────────────────────────────

# Accumulated stripped config (for wg setconf)
WG_CONF=""

# Extracted metadata (arrays)
ADDRESSES=()
DNS_SERVERS=()
ENDPOINTS=()
MTU=""

# Parser state
CURRENT_SECTION=""   # "", "Interface", or "Peer"
LINE_NUM=0
SEEN_INTERFACE=0
PEER_COUNT=0

# ── Parse ──────────────────────────────────────────────────────────────

while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    LINE_NUM=$((LINE_NUM + 1))

    # Strip comments: everything from # to end of line.
    # Per wg(8): "Characters after and including a '#' are considered comments"
    line="${raw_line%%\#*}"

    # Strip leading and trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip empty lines (after comment/whitespace stripping)
    [[ -z "${line}" ]] && continue

    # ── Section headers ──────────────────────────────────────────────
    if [[ "${line}" == "["* ]]; then
        # Must be exactly [Interface] or [Peer]
        case "${line}" in
            "[Interface]")
                SEEN_INTERFACE=$((SEEN_INTERFACE + 1))
                if [[ ${SEEN_INTERFACE} -gt 1 ]]; then
                    die_parse "multiple [Interface] sections are not allowed"
                fi
                CURRENT_SECTION="Interface"
                # Section headers pass through to wg setconf
                WG_CONF+="${line}"$'\n'
                ;;
            "[Peer]")
                PEER_COUNT=$((PEER_COUNT + 1))
                CURRENT_SECTION="Peer"
                WG_CONF+="${line}"$'\n'
                ;;
            *)
                die_parse "unknown section '${line}' (expected [Interface] or [Peer])"
                ;;
        esac
        continue
    fi

    # ── Key = Value pairs ────────────────────────────────────────────

    # Lines outside a section header must contain '='
    if [[ "${line}" != *"="* ]]; then
        die_parse "expected Key = Value, got '${line}'"
    fi

    # Split on first '=' only (values can contain '=', e.g., base64 keys)
    key="${line%%=*}"
    value="${line#*=}"

    # Trim whitespace from key and value
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ -z "${key}" ]]; then
        die_parse "empty key"
    fi

    # ── Handle wg-quick-specific Interface keys ──────────────────────

    if [[ "${CURRENT_SECTION}" == "Interface" ]]; then
        case "${key}" in
            Address)
                # Comma-separated list of IP/CIDR addresses
                IFS=',' read -ra addr_parts <<< "${value}"
                for addr in "${addr_parts[@]}"; do
                    # Trim whitespace
                    addr="${addr#"${addr%%[![:space:]]*}"}"
                    addr="${addr%"${addr##*[![:space:]]}"}"
                    [[ -n "${addr}" ]] && ADDRESSES+=("${addr}")
                done
                # Do NOT pass to wg setconf
                continue
                ;;
            DNS)
                # Comma-separated list of DNS server IPs (or search domains)
                IFS=',' read -ra dns_parts <<< "${value}"
                for dns in "${dns_parts[@]}"; do
                    dns="${dns#"${dns%%[![:space:]]*}"}"
                    dns="${dns%"${dns##*[![:space:]]}"}"
                    [[ -n "${dns}" ]] && DNS_SERVERS+=("${dns}")
                done
                continue
                ;;
            MTU)
                MTU="${value}"
                continue
                ;;
            Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)
                # wg-quick directives we don't need — strip silently
                continue
                ;;
        esac
        # All other Interface keys (PrivateKey, ListenPort, FwMark)
        # pass through to wg setconf
    fi

    # ── Extract Endpoint from Peer sections ──────────────────────────

    if [[ "${CURRENT_SECTION}" == "Peer" && "${key}" == "Endpoint" ]]; then
        ENDPOINTS+=("${value}")
    fi

    # ── Pass through to wg setconf ───────────────────────────────────
    WG_CONF+="${key} = ${value}"$'\n'

done < "${CONFIG_FILE}"

# ── Validation ─────────────────────────────────────────────────────────

if [[ ${SEEN_INTERFACE} -eq 0 ]]; then
    die_validate "no [Interface] section found"
fi

if [[ ${#ADDRESSES[@]} -eq 0 ]]; then
    die_validate "no Address specified in [Interface]"
fi

if [[ ${#DNS_SERVERS[@]} -eq 0 ]]; then
    die_validate "no DNS specified in [Interface] — required for VPN confinement"
fi

if [[ ${PEER_COUNT} -eq 0 ]]; then
    die_validate "no [Peer] sections found"
fi

# ── Write output files ─────────────────────────────────────────────────

# Stripped wg config
printf '%s' "${WG_CONF}" > "${OUTPUT_DIR}/wg.conf"

# Addresses (one per line)
printf '%s\n' "${ADDRESSES[@]}" > "${OUTPUT_DIR}/addresses"

# DNS servers (one per line)
printf '%s\n' "${DNS_SERVERS[@]}" > "${OUTPUT_DIR}/dns"

# Endpoints (one per line), may be empty if no endpoints specified
if [[ ${#ENDPOINTS[@]} -gt 0 ]]; then
    printf '%s\n' "${ENDPOINTS[@]}" > "${OUTPUT_DIR}/endpoints"
else
    : > "${OUTPUT_DIR}/endpoints"
fi

# MTU (only if set)
if [[ -n "${MTU}" ]]; then
    printf '%s\n' "${MTU}" > "${OUTPUT_DIR}/mtu"
fi

echo "${PROG}: parsed successfully — ${#ADDRESSES[@]} address(es), ${#DNS_SERVERS[@]} DNS server(s), ${PEER_COUNT} peer(s)"
