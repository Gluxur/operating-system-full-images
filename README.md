# HAOS Full Images

This repository contains a builder for Home Assistant OS images with preloaded
images of the latest Home Assistant components. This allows for offline
installation of Home Assistant OS with the latest versions and minimal wait
on the first boot.

## Usage

```bash
# Build the builder container
make docker-image

# Build a single image
make build IMAGE=haos_green-17.0.img.xz

# Build all images in input/
make build-all

# Use beta channel
make build IMAGE=haos_green-17.0.img.xz CHANNEL=beta

# Pre-fetch containers
make fetch BOARD=green

# Include custom apps (see "Custom Apps" below)
cp apps.example.yaml apps.yaml
make build IMAGE=haos_green-17.0.img.xz

# Interactive shell for debugging
make shell
```

## Make Targets

| Target | Description |
|--------|-------------|
| `docker-image` | Build the builder container |
| `build IMAGE=<file>` | Build single full image |
| `build-all` | Build all images in `input/` |
| `fetch BOARD=<name>` | Download containers only |
| `fetch-apps BOARD=<name>` | Download custom app repositories and images only |
| `clean` | Clean work directory |
| `shell` | Interactive shell in container |

## Directories

| Path | Description |
|------|-------------|
| `cache/` | Container image and app repository cache |
| `input/` | Place HAOS images here |
| `output/` | Built images appear here |


## Embedded Containers

Latest supervisor, homeassistant, dns, audio, cli, multicast, observer

Versions fetched from `version.home-assistant.io` based on `CHANNEL` (default: `stable`).


## Custom Apps

Custom app repositories and pre-installed apps can be embedded in the image
with an apps configuration file. `make` mounts `./apps.yaml` automatically
when it exists; use `APPS_CONFIG=<file>` to point to another file. See
[`apps.example.yaml`](apps.example.yaml) for all options.

```yaml
repositories:
  - https://github.com/alexbelgium/hassio-addons

apps:
  - repository: core        # official repository
    slug: mosquitto
  - repository: https://github.com/home-assistant/addons-example
    slug: example
    image: ghcr.io/home-assistant/app-example   # optional override
    version: 1.3.1                              # optional override
    boot: auto
    options:
      message: "Hello"
```

During the build:

- every repository (listed ones and the ones of the apps) is cloned and
  embedded in the data partition, and registered in the Supervisor store, so
  the store works without network access on first boot;
- the image of each app is downloaded for the board architecture (`{arch}` in
  the image name is replaced by `amd64` or `aarch64`) and pre-loaded in Docker;
- each app is registered as installed with the configured options, so the
  Supervisor starts it on first boot without downloading anything.

Apps that are built locally (no `image` in their `config.yaml`) need an
`image` in the apps configuration pointing to a pre-built image.

For images in private registries, pass a container registry credentials file
(`auth.json` format, as produced by `docker login` or `skopeo login`):

```bash
make build IMAGE=haos_green-17.0.img.xz REGISTRY_AUTH_FILE=~/.docker/config.json
```

The GitHub workflow picks up an `apps.yaml` committed at the root of the
repository.
