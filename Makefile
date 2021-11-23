# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# Directories.
#
BIN_DIR := bin
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/$(BIN_DIR)

#
# Build.
#
GO111MODULE = on
export GO111MODULE
GOFLAGS ?= -mod=vendor
export GOFLAGS
GOPROXY ?=
export GOPROXY
DBG ?= 0
ifeq ($(DBG),1)
GOGCFLAGS ?= -gcflags=all="-N -l"
endif
GOARCH  ?= $(shell go env GOARCH)
GOOS    ?= $(shell go env GOOS)
VERSION     ?= $(shell git describe --always --abbrev=7)
REPO_PATH   ?= sigs.k8s.io/cluster-api-provider-aws
LD_FLAGS    ?= -X $(REPO_PATH)/pkg/version.Raw=$(VERSION) -extldflags "-static"
MUTABLE_TAG ?= latest
IMAGE        = origin-aws-machine-controllers
BUILD_IMAGE ?= registry.ci.openshift.org/openshift/release:golang-1.17
NO_DOCKER ?= 0

ifeq ($(shell command -v podman > /dev/null 2>&1 ; echo $$? ), 0)
	ENGINE=podman
else ifeq ($(shell command -v docker > /dev/null 2>&1 ; echo $$? ), 0)
	ENGINE=docker
else
	NO_DOCKER=1
endif

USE_DOCKER ?= 0
ifeq ($(USE_DOCKER), 1)
	ENGINE=docker
endif

ifeq ($(NO_DOCKER), 1)
  DOCKER_CMD = CGO_ENABLED=$(CGO_ENABLED) GOARCH=$(GOARCH) GOOS=$(GOOS)
  IMAGE_BUILD_CMD = imagebuilder
else
  DOCKER_CMD = $(ENGINE) run --rm -e CGO_ENABLED=$(CGO_ENABLED) -e GOARCH=arm64 -e GOOS=linux -v "$(PWD)":/go/src/sigs.k8s.io/cluster-api-provider-aws:Z -w /go/src/sigs.k8s.io/cluster-api-provider-aws $(BUILD_IMAGE)
  IMAGE_BUILD_CMD = $(ENGINE) build
endif

#
# Kubebuilder.
#
export KUBEBUILDER_ENVTEST_KUBERNETES_VERSION ?= 1.22.0
export KUBEBUILDER_CONTROLPLANE_START_TIMEOUT ?= 60s
export KUBEBUILDER_CONTROLPLANE_STOP_TIMEOUT ?= 60s

#
# Binaries.
#
SETUP_ENVTEST := $(abspath $(TOOLS_BIN_DIR)/setup-envtest)

$(SETUP_ENVTEST): $(TOOLS_DIR)/go.mod # Build setup-envtest from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -mod=readonly -o $(BIN_DIR)/setup-envtest sigs.k8s.io/controller-runtime/tools/setup-envtest

# race tests need CGO_ENABLED, everything else should have it disabled
CGO_ENABLED = 0
unit : CGO_ENABLED = 1

.PHONY: all
all: generate build images check

.PHONY: vendor
vendor:
	$(DOCKER_CMD) hack/go-mod.sh

.PHONY: generate
generate: gogen goimports

gogen:
	$(DOCKER_CMD) go generate ./pkg/... ./cmd/...

.PHONY: test
test: ## Run tests
	@echo -e "\033[32mTesting...\033[0m"
	$(DOCKER_CMD) hack/ci-test.sh

bin:
	@mkdir $@

.PHONY: build
build: ## build binaries
	$(DOCKER_CMD) go build $(GOGCFLAGS) -o "$(BIN_DIR)/machine-controller-manager" \
               -ldflags "$(LD_FLAGS)" "$(REPO_PATH)/cmd/manager"
	$(DOCKER_CMD) go build  $(GOGCFLAGS) -o "$(BIN_DIR)/termination-handler" \
	             -ldflags "$(LD_FLAGS)" "$(REPO_PATH)/cmd/termination-handler"

.PHONY: images
images: ## Create images
ifeq ($(NO_DOCKER), 1)
	./hack/imagebuilder.sh
endif
	$(IMAGE_BUILD_CMD) -t "$(IMAGE):$(VERSION)" -t "$(IMAGE):$(MUTABLE_TAG)" ./

.PHONY: push
push:
	$(ENGINE) push "$(IMAGE):$(VERSION)"
	$(ENGINE) push "$(IMAGE):$(MUTABLE_TAG)"

.PHONY: check
check: fmt vet lint test # Check your code

KUBEBUILDER_ASSETS ?= $(shell $(SETUP_ENVTEST) use --use-env -p path $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))

.PHONY: unit
unit: $(SETUP_ENVTEST) # Run unit test
	KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" $(DOCKER_CMD) go test -race -cover ./cmd/... ./pkg/...

.PHONY: test-e2e
test-e2e: ## Run e2e tests
	 hack/e2e.sh

.PHONY: lint
lint: ## Go lint your code
	$(DOCKER_CMD) hack/go-lint.sh -min_confidence 0.3 $$(go list -f '{{ .ImportPath }}' ./... | grep -v -e 'sigs.k8s.io/cluster-api-provider-aws/test' -e 'sigs.k8s.io/cluster-api-provider-aws/pkg/cloud/aws/client/mock')

.PHONY: fmt
fmt: ## Go fmt your code
	$(DOCKER_CMD) hack/go-fmt.sh .

.PHONY: goimports
goimports:
	$(DOCKER_CMD) hack/goimports.sh .
	hack/verify-diff.sh

.PHONY: vet
vet: ## Apply go vet to all go files
	$(DOCKER_CMD) hack/go-vet.sh ./...

.PHONY: help
help:
	@grep -E '^[a-zA-Z/0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
