GOCLAW_DIR ?= ./goclaw-core
IMAGE      ?= itsddvn/goclaw
VERSION    ?= $(shell cd $(GOCLAW_DIR) && git describe --tags --always 2>/dev/null || echo dev)
PLATFORMS  ?= linux/amd64,linux/arm64
LOCAL_ARCH ?= linux/$(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')

.PHONY: build build-local push all version clean

# Build multi-arch image (requires push or registry)
build:
	docker buildx build \
		--build-context deploy=. \
		--build-arg VERSION=$(VERSION) \
		--platform $(PLATFORMS) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		$(GOCLAW_DIR)

# Build for local platform and load into Docker
build-local:
	docker buildx build \
		--build-context deploy=. \
		--build-arg VERSION=$(VERSION) \
		--platform $(LOCAL_ARCH) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		--load \
		$(GOCLAW_DIR)

# Build multi-arch and push to DockerHub
push:
	docker buildx build \
		--build-context deploy=. \
		--build-arg VERSION=$(VERSION) \
		--platform $(PLATFORMS) \
		-f Dockerfile \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		--push \
		$(GOCLAW_DIR)

# Build + push
all: push

# Show version
version:
	@echo $(VERSION)

# Remove local images
clean:
	docker rmi $(IMAGE):$(VERSION) $(IMAGE):latest 2>/dev/null || true
