#!/bin/bash
# scripts/fetch-apps.sh - Fetch custom app repositories and images
# Reads the apps configuration (APPS_CONFIG), clones the app repositories and
# downloads the app images, then writes a resolved apps file for create-data.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

register_cleanup

# Read the apps configuration (YAML or JSON) and normalize it
read_apps_config() {
    local config_file="$1"

    yq -e '
        if type != "object" then error("apps configuration must be a mapping") else . end
        | {
            repositories: ((.repositories // []) | map(tostring)),
            apps: ((.apps // []) | map(
                if (.repository | type) != "string" or (.slug | type) != "string"
                then error("each app needs a \"repository\" and a \"slug\"")
                else . end
            ))
        }
    ' "$config_file"
}

# Clone (or refresh) an app repository into the repositories cache
# Repository format follows Supervisor: <url>[#<branch>]
clone_repository() {
    local repository="$1"
    local repo_dir="$2"

    local url="${repository%%#*}"
    local branch=""
    if [[ "$repository" == *"#"* ]]; then
        branch="${repository#*#}"
    fi

    log "Cloning repository: $repository"

    local tmp_dir="${repo_dir}.tmp"
    rm -rf "$tmp_dir"
    git clone --quiet --depth 1 --recursive --shallow-submodules \
        ${branch:+--branch "$branch"} "$url" "$tmp_dir" >&2 \
        || die "Failed to clone repository: $repository"

    local validated=0
    for ext in yaml yml json; do
        if [ -f "${tmp_dir}/repository.${ext}" ]; then
            validated=1
            break
        fi
    done
    [ "$validated" -eq 1 ] || die "Not a valid app repository (no repository.yaml/json): $repository"

    rm -rf "$repo_dir"
    mv "$tmp_dir" "$repo_dir"
}

# Find the directory (relative to repository root) of an app by its slug
find_app_directory() {
    local repo_dir="$1"
    local slug="$2"

    local config_file
    while IFS= read -r config_file; do
        if [ "$(yq -r '.slug // empty' "$config_file" 2>/dev/null)" = "$slug" ]; then
            local app_dir
            app_dir=$(dirname "$config_file")
            echo "${app_dir#"${repo_dir}"}" | sed 's|^/||'
            return 0
        fi
    done < <(find "$repo_dir" -mindepth 1 -maxdepth 3 -path "${repo_dir}/.git" -prune -o \
        -type f \( -name config.yaml -o -name config.yml -o -name config.json \) -print | sort)

    return 1
}

# Read an app's translations directory into a {language: content} object
read_app_translations() {
    local app_dir="$1"
    local translations="{}"

    if [ -d "${app_dir}/translations" ]; then
        local file lang content
        for file in "${app_dir}"/translations/*.yaml "${app_dir}"/translations/*.yml "${app_dir}"/translations/*.json; do
            [ -f "$file" ] || continue
            lang=$(basename "$file")
            lang="${lang%.*}"
            content=$(yq -c '.' "$file" 2>/dev/null) || continue
            translations=$(jq -c --arg lang "$lang" --argjson content "$content" \
                '.[$lang] = $content' <<< "$translations")
        done
    fi

    echo "$translations"
}

# Resolve one app entry: locate its config, compute image and fetch it
# Prints the resolved app as JSON
resolve_app() {
    local app_json="$1"
    local arch="$2"
    local images_dir="$3"
    local repos_dir="$4"

    local repository slug repo_hash
    repository=$(jq -r '.repository' <<< "$app_json")
    slug=$(jq -r '.slug' <<< "$app_json")
    repo_hash=$(get_repository_hash "$repository")

    local repo_dir="${repos_dir}/${repo_hash}"
    local app_path
    app_path=$(find_app_directory "$repo_dir" "$slug") \
        || die "App '$slug' not found in repository $repository"

    local app_dir="${repo_dir}${app_path:+/${app_path}}"
    local config_file=""
    for ext in yaml yml json; do
        if [ -f "${app_dir}/config.${ext}" ]; then
            config_file="${app_dir}/config.${ext}"
            break
        fi
    done

    local config
    config=$(yq -c '.' "$config_file")

    # Check architecture support
    if ! jq -e --arg arch "$arch" '(.arch // []) | index($arch)' <<< "$config" > /dev/null; then
        die "App '$slug' does not support architecture $arch (supports: $(jq -r '(.arch // []) | join(", ")' <<< "$config"))"
    fi

    # Image: explicit override, or the one declared by the app
    local image
    image=$(jq -r --argjson config "$config" '.image // $config.image // empty' <<< "$app_json")
    if [ -z "$image" ]; then
        die "App '$slug' has no pre-built image (local build app); set \"image\" in the apps configuration"
    fi
    image="${image//\{arch\}/$arch}"

    # Version: explicit override, or the one declared by the app
    local version
    version=$(jq -r --argjson config "$config" '(.version // $config.version) | tostring' <<< "$app_json")

    log "App '$slug': image ${image}:${version} (repository ${repo_hash}, path /${app_path})"

    local archive
    archive=$(fetch_image_archive "${image}:${version}" "$arch" "$images_dir")

    jq -n \
        --arg slug "${repo_hash}_${slug}" \
        --arg repository "$repo_hash" \
        --arg repository_url "$repository" \
        --arg path "$app_path" \
        --arg image "$image" \
        --arg version "$version" \
        --arg archive "$archive" \
        --argjson config "$config" \
        --argjson translations "$(read_app_translations "$app_dir")" \
        --argjson entry "$app_json" \
        '{
            slug: $slug,
            repository: $repository,
            repository_url: $repository_url,
            path: $path,
            image: $image,
            version: $version,
            archive: $archive,
            config: ($config | .version = $version),
            translations: $translations,
            user: ($entry | with_entries(select(.key as $k | [
                "options", "boot", "auto_update", "network",
                "audio_input", "audio_output", "protected",
                "ingress_panel", "watchdog"
            ] | index($k))))
        }'
}

main() {
    local board="$1"

    local arch
    arch=$(get_arch "$board")

    local apps_file
    apps_file=$(get_apps_file_path "$board")
    mkdir -p "$CACHE_DIR"

    if [ ! -f "$APPS_CONFIG" ]; then
        log "No apps configuration found at ${APPS_CONFIG}, skipping custom apps"
        echo '{"repositories": [], "apps": []}' > "$apps_file"
        return 0
    fi

    log "Reading apps configuration: ${APPS_CONFIG}"
    local config
    config=$(read_apps_config "$APPS_CONFIG") || die "Invalid apps configuration: ${APPS_CONFIG}"

    local images_dir repos_dir
    images_dir="${CACHE_DIR}/images"
    repos_dir=$(get_repositories_cache_path)
    mkdir -p "$images_dir" "$repos_dir"

    # All repositories: explicitly listed ones plus the ones of the apps
    local repositories_json
    repositories_json=$(jq -c '(.repositories + (.apps | map(.repository))) | unique' <<< "$config")

    local repository
    while IFS= read -r repository; do
        clone_repository "$repository" "${repos_dir}/$(get_repository_hash "$repository")"
    done < <(jq -r '.[]' <<< "$repositories_json")

    # Resolve and fetch each app
    local apps_json="[]"
    local app_json resolved
    while IFS= read -r app_json; do
        resolved=$(resolve_app "$app_json" "$arch" "$images_dir" "$repos_dir")
        apps_json=$(jq -c --argjson app "$resolved" '. + [$app]' <<< "$apps_json")
    done < <(jq -c '.apps[]' <<< "$config")

    local repos_resolved="[]"
    while IFS= read -r repository; do
        repos_resolved=$(jq -c --arg url "$repository" --arg hash "$(get_repository_hash "$repository")" \
            '. + [{url: $url, hash: $hash}]' <<< "$repos_resolved")
    done < <(jq -r '.[]' <<< "$repositories_json")

    jq -n --argjson repositories "$repos_resolved" --argjson apps "$apps_json" \
        '{repositories: $repositories, apps: $apps}' > "$apps_file"

    log "Custom apps resolved:"
    jq -r '.apps[] | "  - \(.slug) \(.image):\(.version)"' "$apps_file" >&2
    log "Custom apps fetch complete"
}

# Entry point
if [ $# -lt 1 ]; then
    die "Usage: $0 <board>"
fi

main "$@"
