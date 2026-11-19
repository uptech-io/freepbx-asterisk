# shellcheck shell=bash

# Root runs the hooks: only root may be able to change one (a link never passes).
function hook_trusted() {
    [[ -z "$(find "$1" "${1%/*}" -maxdepth 0 \( ! -user root -o -perm /022 \) 2>&1)" ]]
}

function load_nftables_configs() {
    local hooks_dir="${1:?hooks_dir required}"
    local config_dir="${hooks_dir}/nftables.d"
    
    local -a nft_args=()
    local ipvlan_if="$(ipvlan_iface)"
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'

    if [[ -n "${ipvlan_if}" ]]; then
        nft_args+=(--define "ipvlan_if=${ipvlan_if}")
    fi

    # nft and Apache both read it, and each accepts forms the other refuses (names, IPv6, /0).
    [[ "${PROXY_SUBNET-}" =~ ^${octet}\.${octet}\.${octet}\.${octet}(/(3[0-2]|[12][0-9]|[1-9]))?$ ]] || {
        log "Error: PROXY_SUBNET is not one IPv4 address or network in CIDR notation (prefix 1 to 32)."
        exit 1
    }

    log "Loading nftables basic rules..."

    nft "${nft_args[@]}" --define "proxy_subnet=${PROXY_SUBNET}" -f /etc/nftables.nft || {
        log "Error: nftables base rules failed to load (is NET_ADMIN granted?)."
        exit 1
    }

    log "Loading nftables configurations from ${config_dir}"
    if [[ -d "${config_dir}" ]]; then
        local file

        # A hook left out would leave the firewall other than the operator asked for: do not start.
        for file in "${config_dir}"/*.nft; do
            [[ -f "${file}" ]] || continue

            hook_trusted "${file}" || {
                log "Error: nftables hook ${file} is not owned by root, or others can write to it."
                exit 1
            }

            log "Applying nftables configuration: ${file}"
            nft "${nft_args[@]}" -f "${file}" || {
                log "Error: nftables hook ${file} failed to load."
                exit 1
            }
        done
    fi

    # A hook with "flush ruleset" or "delete table" loads without error and takes the base rules away.
    local input
    input="$(nft list chain inet filter input 2>&1)"

    if ! grep -q 'hook input.*policy drop' <<< "${input}" || ! grep -qF 'iifname "lo" accept' <<< "${input}"; then
        log "Error: the nftables hooks left inet filter input without its drop policy or its loopback rule."
        exit 1
    fi

    # Added after the hooks' rules, to record only what the drop policy is about to take:
    # source, protocol and port, read with "nft list set inet filter dropv4".
    nft add rule inet filter input 'meta l4proto { tcp, udp } meter dropv4 size 8192 { ip saddr . meta l4proto . th dport timeout 10m counter }' \
        && nft add rule inet filter input 'meta l4proto { tcp, udp } meter dropv6 size 8192 { ip6 saddr . meta l4proto . th dport timeout 10m counter }' \
        || log "Warning: the nftables drop record was not added."
}

function run_bash_scripts() {
    local hooks_dir="${1:?hooks_dir required}"
    local scripts_dir="${hooks_dir}/scripts.d"

    log "Executing bash scripts in ${scripts_dir}"
    if [[ -d "${scripts_dir}" ]]; then
        local script

        for script in "${scripts_dir}"/*.sh; do
            [[ -f "${script}" ]] || continue

            hook_trusted "${script}" || {
                log "Warning: skipping ${script}: not owned by root, or others can write to it."
                continue
            }

            log "Running script: ${script}"
            bash "${script}"
        done
    fi
}
