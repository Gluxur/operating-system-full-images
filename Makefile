# HAOS Full Image Builder - Host Makefile
# Runs the builder container

IMAGE_NAME ?= haos-full-builder
INPUT_DIR ?= $(CURDIR)/input
OUTPUT_DIR ?= $(CURDIR)/output
CACHE_DIR ?= $(CURDIR)/cache
CHANNEL ?= stable
APPS_CONFIG ?= $(CURDIR)/apps.yaml
REGISTRY_AUTH_FILE ?=

# Optional mounts: custom apps configuration and registry credentials
EXTRA_MOUNTS = \
	$(if $(wildcard $(APPS_CONFIG)),-v "$(abspath $(APPS_CONFIG)):/config/apps.yaml:ro") \
	$(if $(REGISTRY_AUTH_FILE),-v "$(abspath $(REGISTRY_AUTH_FILE)):/config/auth.json:ro" -e REGISTRY_AUTH_FILE=/config/auth.json)

DOCKER_RUN = docker run --rm --privileged \
	-v "$(INPUT_DIR):/input" \
	-v "$(OUTPUT_DIR):/output" \
	-v "$(CACHE_DIR):/cache" \
	$(EXTRA_MOUNTS) \
	-e CHANNEL=$(CHANNEL) \
	$(if $(DIND_IMAGE),-e DIND_IMAGE=$(DIND_IMAGE)) \
	-e HOST_UID=$(shell id -u) \
	-e HOST_GID=$(shell id -g) \
	-e LOG_COLOR=1 \
	$(IMAGE_NAME)

.PHONY: help docker-image build build-all fetch fetch-apps clean shell

help:
	@echo "HAOS Full Image Builder"
	@echo ""
	@echo "Host targets:"
	@echo "  make docker-image          Build the builder container"
	@echo "  make build IMAGE=<file>    Build a single full image"
	@echo "  make build-all             Build all images in input/"
	@echo "  make fetch BOARD=<b>       Fetch containers and custom apps for board"
	@echo "  make fetch-apps BOARD=<b>  Fetch custom apps only for board"
	@echo "  make clean                 Clean work directory"
	@echo "  make shell                 Interactive shell in container"
	@echo ""
	@echo "Options:"
	@echo "  IMAGE=<file>       Input image filename (e.g., haos_green-17.0.img.xz)"
	@echo "  BOARD=<name>       Board name (e.g., green, ova)"
	@echo "  CHANNEL=<channel>  Version channel: stable, beta, dev (default: stable)"
	@echo "  APPS_CONFIG=<file> Custom apps configuration (default: ./apps.yaml, optional)"
	@echo "  REGISTRY_AUTH_FILE=<file>  Registry credentials for private app images (optional)"

docker-image:
	docker build -t $(IMAGE_NAME) $(if $(DIND_IMAGE),--build-arg DIND_IMAGE=$(DIND_IMAGE)) .

build:
ifndef IMAGE
	$(error IMAGE is required. Usage: make build IMAGE=<filename>)
endif
	@mkdir -p "$(INPUT_DIR)" "$(OUTPUT_DIR)" "$(CACHE_DIR)"
	$(DOCKER_RUN) build IMAGE=/input/$(IMAGE)

build-all:
	@mkdir -p "$(INPUT_DIR)" "$(OUTPUT_DIR)" "$(CACHE_DIR)"
	$(DOCKER_RUN) build-all

fetch:
ifndef BOARD
	$(error BOARD is required. Usage: make fetch BOARD=<board>)
endif
	@mkdir -p "$(CACHE_DIR)"
	$(DOCKER_RUN) fetch-containers BOARD=$(BOARD)

fetch-apps:
ifndef BOARD
	$(error BOARD is required. Usage: make fetch-apps BOARD=<board>)
endif
	@mkdir -p "$(CACHE_DIR)"
	$(DOCKER_RUN) fetch-apps BOARD=$(BOARD)

clean:
	$(DOCKER_RUN) clean-all

shell:
	@mkdir -p "$(INPUT_DIR)" "$(OUTPUT_DIR)" "$(CACHE_DIR)"
	docker run --rm -it --privileged \
		-v "$(INPUT_DIR):/input" \
		-v "$(OUTPUT_DIR):/output" \
		-v "$(CACHE_DIR):/cache" \
		$(EXTRA_MOUNTS) \
		-e LOG_COLOR=1 \
		--entrypoint /bin/bash \
		$(IMAGE_NAME)
