#!/bin/bash
# scripts/fetch-containers.sh - Fetch container images via skopeo
# Downloads all required Home Assistant containers for a board

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

register_cleanup

fetch_versions() {
    local channel="$1"
    local arch="$2"
    local machine="$3"

    curl -fsSL "${VERSION_ENDPOINT}/${channel}.json" | jq \
        --arg arch "$arch" \
        --arg machine "$machine" \
        '{
            supervisor: .supervisor,
            homeassistant: .homeassistant[$machine],
            dns: .dns,
            audio: .audio,
            cli: .cli,
            multicast: .multicast,
            observer: .observer,
            images: (.images | to_entries | map(
                # API uses "core" for what we call "homeassistant"
                {key: (if .key == "core" then "homeassistant" else .key end),
                 value: (.value | gsub("\\{arch\\}"; $arch) | gsub("\\{machine\\}"; $machine))}
            ) | from_entries)
        }'
}

fetch_container() {
    local name="$1"
    local arch="$2"
    local output_dir="$3"
    local versions_file="$4"

    local image
    image=$(get_container_image "$versions_file" "$name")

    fetch_image_archive "$image" "$arch" "$output_dir" > /dev/null
}

main() {
    local board="$1"
    local channel="${2:-$CHANNEL}"

    local arch machine
    arch=$(get_arch "$board")
    machine=$(get_machine "$board")

    log "Fetching containers for board: $board (arch: $arch, machine: $machine)"
    log "Using channel: $channel"

    # Create shared images directory
    local images_dir="${CACHE_DIR}/images"
    mkdir -p "$images_dir"

    # Fetch version information
    log "Fetching version information from ${VERSION_ENDPOINT}/${channel}.json..."
    local version_json
    version_json=$(fetch_versions "$channel" "$arch" "$machine")

    # Save as board-specific versions file
    echo "$version_json" > "${CACHE_DIR}/versions-${board}.json"
    log "Versions:"
    echo "$version_json" | jq .

    # Fetch each container into shared images directory
    local versions_file="${CACHE_DIR}/versions-${board}.json"
    for container in $CONTAINERS; do
        local version
        version=$(echo "$version_json" | jq -r ".${container}")

        if [ "$version" = "null" ] || [ -z "$version" ]; then
            die "No version found for $container"
        fi

        fetch_container "$container" "$arch" "$images_dir" "$versions_file"
    done

    log "Container fetch complete"
    log "Total cache size: $(du -sh "$images_dir" | cut -f1)"
}

# Entry point
if [ $# -lt 1 ]; then
    die "Usage: $0 <board> [channel]"
fi

main "$@"
