#!/bin/bash
# scripts/create-data.sh - Create new data partition
# Creates oversized partition, imports containers, then shrinks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

register_cleanup
require_root

# Global variable for loop device tracking across functions
declare MOUNT_LOOP=""

create_working_partition() {
    local size_mb="$1"
    local new_image
    new_image="$(get_new_data_image_path)"

    # Source original settings
    # shellcheck disable=SC1090
    source "$(get_original_settings_path)"

    log "Creating ${size_mb}M ext4 partition..."

    # Create sparse file
    truncate --size="${size_mb}M" "$new_image"

    # Create ext4 filesystem with original UUID and label
    mkfs.ext4 \
        -L "${ORIGINAL_LABEL:-hassos-data}" \
        -U "${ORIGINAL_UUID}" \
        -E lazy_itable_init=0,lazy_journal_init=0 \
        "$new_image"

    log "Created filesystem with UUID: ${ORIGINAL_UUID}"
}

mount_new_data() {
    local new_data new_image
    new_data=$(get_data_content_path)
    new_image="$(get_new_data_image_path)"

    # Create mount point
    mkdir -p "$new_data"

    log "Mounting new partition..."
    MOUNT_LOOP=$(setup_loop "$new_image")
    log "Using loop device: $MOUNT_LOOP"
    mount "$MOUNT_LOOP" "$new_data"
    track_mount "$new_data"
}

unmount_new_data() {
    local new_data new_image
    new_data=$(get_data_content_path)
    new_image="$(get_new_data_image_path)"

    umount "$new_data"
    detach_loop "$MOUNT_LOOP"
}

get_board_image_files() {
    local board="$1"

    local images_dir="${CACHE_DIR}/images"
    local versions_file="${CACHE_DIR}/versions-${board}.json"

    require_file "$versions_file"
    require_directory "$images_dir"

    for container in $CONTAINERS; do
        local image image_prefix
        image=$(get_container_image "$versions_file" "$container")

        image_prefix="${image//[:\/]/_}"
        local image_file
        image_file=$(ls "${images_dir}/${image_prefix}"@*.tar 2>/dev/null | head -1 || true)

        if [ -z "$image_file" ]; then
            die "Image not found in cache: ${image_prefix}"
        fi

        echo "$image_file"
    done

    # Custom app images
    local apps_file
    apps_file=$(get_apps_file_path "$board")
    if [ -f "$apps_file" ]; then
        local archive
        while IFS= read -r archive; do
            [ -f "$archive" ] || die "App image not found in cache: $archive"
            echo "$archive"
        done < <(jq -r '.apps[].archive' "$apps_file")
    fi
}

import_containers() {
    local board="$1"
    local manifest="$2"

    log "Importing containers into data partition..."

    local new_data
    new_data=$(get_data_content_path)

    # Create docker directory
    local docker_dir="${new_data}/docker"
    mkdir -p "${docker_dir}"

    # Wait for Docker to be ready
    log "Waiting for Docker daemon..."
    local retries=60
    while ! docker version &>/dev/null; do
        sleep 1
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            cat /var/log/dockerd-import.log >&2
            die "Docker daemon failed to start with custom data root"
        fi
    done

    log "Docker daemon ready"

    local images_dir="${CACHE_DIR}/images"

    # Use official Docker in Docker images
    container=$(docker run --privileged -e DOCKER_TLS_CERTDIR="" \
        -v "${docker_dir}":/mnt/data/docker \
        -v "${SCRIPT_DIR}":/scripts \
        -v "${images_dir}:${images_dir}:ro" \
        -v "${manifest}:${manifest}:ro" \
        -d "${DIND_IMAGE}" --feature containerd-snapshotter --data-root /mnt/data/docker)

    # Run import script
    log "Loading container images..."
    docker exec "${container}" sh "/scripts/dind-import.sh" "${manifest}"

    docker rm -f "${container}"

    log "Container import complete"
}

configure_supervisor() {
    local board="$1"
    local versions_file="$2"
    local channel="$3"

    local new_data new_image
    new_data=$(get_data_content_path)
    new_image="$(get_new_data_image_path)"

    require_file "$versions_file"

    log "Configuring supervisor for pre-loaded images..."

    # Get versions from the fetched versions.json
    local ha_version supervisor_version
    ha_version=$(jq -r '.homeassistant' "$versions_file")
    supervisor_version=$(jq -r '.supervisor' "$versions_file")

    log "Configuring Home Assistant version: $ha_version"
    log "Configuring Supervisor version: $supervisor_version"

    # Ensure supervisor directory exists
    mkdir -p "${new_data}/supervisor"

    # Update homeassistant.json with the pre-loaded version
    local ha_config="${new_data}/supervisor/homeassistant.json"
    local ha_image
    ha_image=$(get_container_image_name "$versions_file" "homeassistant")

    if [ -f "$ha_config" ]; then
        # Update existing config
        jq --arg version "$ha_version" --arg image "$ha_image" \
            '.version = $version | .image = $image' \
            "$ha_config" > "${ha_config}.tmp" && mv "${ha_config}.tmp" "$ha_config"
    else
        log "homeassistant.json not found in supervisor directory, creating new configuration"
        # Create new config with minimal required fields
        jq -n --arg version "$ha_version" --arg image "$ha_image" \
            '{version: $version, image: $image, port: 8123, ssl: false, watchdog: true, boot: true}' \
            > "$ha_config"
    fi

    log "Updated homeassistant.json:"
    cat "$ha_config"

    # Setup AppArmor
    APPARMOR_URL="https://version.home-assistant.io/apparmor_${channel}.txt"
    mkdir -p "${new_data}/supervisor/apparmor"
    curl -fsL -o "${new_data}/supervisor/apparmor/hassio-supervisor" "${APPARMOR_URL}"

    # Persist updater channel
    jq -n --arg channel "${channel}" '{"channel": $channel}' > "${new_data}/supervisor/updater.json"

    log "Supervisor configuration complete"
}

generate_token() {
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
}

configure_apps() {
    local board="$1"

    local apps_file
    apps_file=$(get_apps_file_path "$board")
    if [ ! -f "$apps_file" ] || jq -e '(.repositories | length) == 0' "$apps_file" > /dev/null; then
        log "No custom apps configured"
        return 0
    fi

    local new_data supervisor_dir repos_dir
    new_data=$(get_data_content_path)
    supervisor_dir="${new_data}/supervisor"
    repos_dir=$(get_repositories_cache_path)

    log "Configuring custom apps..."

    # Legacy "addons" layout and file names are used on purpose: every
    # Supervisor version reads them, newer ones migrate them to "apps"
    mkdir -p "${supervisor_dir}/addons/git" "${supervisor_dir}/addons/data"

    # Register repositories in the store (built-in ones are added by Supervisor)
    local store_config="${supervisor_dir}/store.json"
    jq '{repositories: [.repositories[] | select(.slug != "core") | .url]}' "$apps_file" > "$store_config"
    log "Store repositories:"
    cat "$store_config"

    # Pre-clone repositories so the store works without network on first boot
    local repo_slug location
    while IFS= read -r repo_slug; do
        require_directory "${repos_dir}/${repo_slug}"
        location=$(get_repository_location "$repo_slug")
        mkdir -p "${supervisor_dir}/addons/${location}"
        rsync -a "${repos_dir}/${repo_slug}/" "${supervisor_dir}/addons/${location}/"
    done < <(jq -r '.repositories[].slug' "$apps_file")

    # Mark apps as installed
    local apps_config="${supervisor_dir}/addons.json"
    local installed='{"user": {}, "system": {}}'
    local app_json slug
    while IFS= read -r app_json; do
        slug=$(jq -r '.slug' <<< "$app_json")
        log "Installing app: $slug"

        mkdir -p "${supervisor_dir}/addons/data/${slug}"

        installed=$(jq -c \
            --argjson app "$app_json" \
            --arg location "/data/addons/$(get_repository_location "$(jq -r '.repository' <<< "$app_json")")" \
            --arg uuid "$(cat /proc/sys/kernel/random/uuid | tr -d '-')" \
            --arg ingress_token "$(generate_token)" \
            '.system[$app.slug] = ($app.config + {
                repository: $app.repository,
                location: ($location
                    + (if $app.path == "" then "" else "/" + $app.path end)),
                translations: $app.translations
            })
            | .user[$app.slug] = ({
                version: $app.version,
                image: $app.image,
                uuid: $uuid,
                ingress_token: $ingress_token,
                options: {},
                protected: true
            } + $app.user)' <<< "$installed")
    done < <(jq -c '.apps[]' "$apps_file")

    jq . <<< "$installed" > "$apps_config"
    log "Installed apps: $(jq -r '.user | keys | join(", ")' "$apps_config")"
}

copy_preserved_data() {
    local old_data new_data
    old_data=$(get_original_data_path)
    new_data=$(get_data_content_path)

    log "Copying preserved data from old partition..."

    rsync -a "${old_data}/" "${new_data}/"
}

shrink_partition() {
    local new_image
    new_image="$(get_new_data_image_path)"

    new_data=$(get_data_content_path)

    log "Shrinking partition to minimum size..."

    # Check filesystem
    log "Checking filesystem..."
    e2fsck -f -y "$new_image"

    # Shrink filesystem to minimum
    log "Resizing filesystem to minimum..."
    resize2fs -M "$new_image"

    # Get new filesystem size
    local block_count block_size new_size_bytes
    block_count=$(dumpe2fs -h "$new_image" 2>/dev/null | grep "Block count:" | awk '{print $3}')
    block_size=$(dumpe2fs -h "$new_image" 2>/dev/null | grep "Block size:" | awk '{print $3}')
    new_size_bytes=$((block_count * block_size))

    # Truncate image file to match filesystem
    log "Truncating image to ${new_size_bytes} bytes ($(bytes_to_human "$new_size_bytes"))"
    truncate --size="${new_size_bytes}" "$new_image"

    # Save new size info
    echo "NEW_DATA_SIZE=$new_size_bytes" >> "$(get_original_settings_path)"
}

main() {
    local board="$1"
    local channel="$2"

    local versions_file="${CACHE_DIR}/versions-${board}.json"
    local images_dir="${CACHE_DIR}/images"

    require_file "$versions_file"
    require_directory "$images_dir"

    log "Creating new data partition for board: $board"

    # Build manifest of images needed for this board
    local manifest="${WORK_DIR}/image-manifest.txt"
    get_board_image_files "$board" > "$manifest"

    log "Images for this board:"
    cat "$manifest" >&2

    # Calculate required working size from manifest
    local container_size_bytes=0
    while IFS= read -r image_file; do
        local file_size
        file_size=$(stat -c%s "$image_file")
        container_size_bytes=$((container_size_bytes + file_size))
    done < "$manifest"
    local container_size=$((container_size_bytes / 1048576))

    # Reserve 4x container size + 1G overhead
    local work_size_mb=$((container_size * 4 + 1024))

    log "Container archive size: ${container_size}M"
    log "Working partition size: ${work_size_mb}M"

    # Create oversized working partition
    create_working_partition "$work_size_mb"

    # Mount new data partition
    mount_new_data

    # Import containers using local docker
    import_containers "$board" "$manifest"

    # Configure supervisor to use pre-loaded images and correct channel
    configure_supervisor "$board" "$versions_file" "$channel"

    # Register custom app repositories and pre-installed apps
    configure_apps "$board"

    # Copy preserved files from old data partition
    copy_preserved_data

    # Unmount new data partition
    unmount_new_data

    # Shrink partition to minimum size
    shrink_partition

    # Move to label-based path for genimage
    local final_path
    final_path="$(get_partition_image_path "hassos-data")"
    mv "$(get_new_data_image_path)" "$final_path"

    log "New data partition created: $final_path"
    log "Final size: $(du -h "$final_path" | cut -f1)"
}

# Entry point
if [ $# -lt 2 ]; then
    die "Usage: $0 <board> <channel>"
fi

main "$1" "$2"
