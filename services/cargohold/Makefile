LANG := en_US.UTF-8
SHELL         := /usr/bin/env bash
NAME          := cargohold
VERSION       ?=
BUILD_NUMBER  ?= 0
BUILD_LABEL   ?= local
BUILD         := $(BUILD_NUMBER)$(shell [ "${BUILD_LABEL}" == "" ] && echo "" || echo ".${BUILD_LABEL}")
EXE_IT        := ../../dist/$(NAME)-integration
DEB           := dist/$(NAME)_$(VERSION)+$(BUILD)_amd64.deb
DEB_IT        := dist/$(NAME)-integration_$(VERSION)+$(BUILD)_amd64.deb
SDIST         := dist/$(NAME)-$(VERSION).tar.gz
EXECUTABLES   := $(NAME) $(NAME)-integration
DOCKER_USER    ?= quay.io/wire
DOCKER_TAG     ?= local

guard-%:
	@ if [ "${${*}}" = "" ]; then \
	      echo "Environment variable $* not set"; \
	    exit 1; \
	fi

default: fast

.PHONY: init
init:
	mkdir -p ../../dist

.PHONY: install
install: init
	stack install . --pedantic --test --bench --no-run-benchmarks --local-bin-path=dist

.PHONY: fast
fast: init
	stack install . --pedantic --test --bench --no-run-benchmarks --local-bin-path=dist --fast $(WIRE_STACK_OPTIONS)

.PHONY: compile
compile:
	stack build . --pedantic --test --bench --no-run-benchmarks --no-copy-bins

.PHONY: clean
clean: init
	stack clean $(NAME)

.PHONY: i
i:
	../integration.sh $(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml $(WIRE_INTEGRATION_TEST_OPTIONS)

.PHONY: i-aws
i-aws:
	INTEGRATION_USE_REAL_AWS=1 ../integration.sh $(EXE_IT) -s $(NAME).integration-aws.yaml -i ../integration.yaml $(WIRE_INTEGRATION_TEST_OPTIONS)

.PHONY: i-list
i-list:
	$(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml -l

i-%:
	../integration.sh $(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml -p "$*" $(WIRE_INTEGRATION_TEST_OPTIONS)

# Before using this target, create a symlink to a directory containing configurations to
# test different S3-like buckets to see if cargohold can interact with them.
#   ln -s /path/to/private/folder compat
# If you have a folder compat/minio, run e.g.
#   make compat-minio
# Currently only the "simple" integration test group is run.
.PHONY: compat-%
compat-%:
	INTEGRATION_CARGOHOLD_ONLY_COMPAT=1 CARGOHOLD_COMPAT_CONFIG_FOLDER=compat/$* ../integration.sh $(EXE_IT) -s compat/$*/cargohold.integration.yaml -i ../integration.yaml -p simple $(WIRE_INTEGRATION_TEST_OPTIONS)

.PHONY: integration
integration: fast i

.PHONY: integration-list
integration-list: fast i-list

integration-%: fast
	make "i-$*"

.PHONY: docker
docker:
	$(foreach executable,$(EXECUTABLES),\
	docker build -t $(DOCKER_USER)/$(executable):$(DOCKER_TAG) \
	-f ../../build/ubuntu/Dockerfile.executable \
	--build-arg executable=$(executable) \
	../.. && \
	docker tag $(DOCKER_USER)/$(executable):$(DOCKER_TAG) $(DOCKER_USER)/$(executable):latest && \
	if test -n "$$DOCKER_PUSH"; then docker login -u $(DOCKER_USERNAME) -p $(DOCKER_PASSWORD); docker push $(DOCKER_USER)/$(executable):$(DOCKER_TAG); docker push $(DOCKER_USER)/$(executable):latest; fi \
	;)

.PHONY: time
time: clean
	-rm -f .stack-work/logs/*
	stack build . --pedantic --no-run-benchmarks --no-copy-bins --ghc-options="-j +RTS -s -RTS"
	@echo -e "\nTotal wall-clock times taken to compile each module (see logs for more detail):"
	@grep Total .stack-work/logs/* | tr -s ' ' | awk -F' ' '{gsub(/s$$/, "", $$6); a[$$1] += $$6}END{for (i in a) {m=gensub(/^.*\/logs\//,"",1,i); m=gensub(/-[0-9].*\.log/,"",1,m); print m, a[i] ++ "s"}}' | sort -grk2
