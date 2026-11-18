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

    if [[ -n "${ipvlan_if}" ]]; then
        nft_args+=(--define "ipvlan_if=${ipvlan_if}")
    fi

    log "Loading nftables basic rules..."
    # Without the base rules SIP would be open and fail2ban could not block: do not start.
    nft "${nft_args[@]}" -f /etc/nftables.nft || {
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
