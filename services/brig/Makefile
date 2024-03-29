LANG := en_US.UTF-8
SHELL         := /usr/bin/env bash
NAME          := brig
VERSION       ?=
BUILD_NUMBER  ?= 0
BUILD_LABEL   ?= local
BUILD         := $(BUILD_NUMBER)$(shell [ "${BUILD_LABEL}" == "" ] && echo "" || echo ".${BUILD_LABEL}")
EXE_IT        := ../../dist/$(NAME)-integration
EXE_SCHEMA    := ../../dist/$(NAME)-schema
EXE_INDEX     := ../../dist/$(NAME)-index
DEB           := dist/$(NAME)_$(VERSION)+$(BUILD)_amd64.deb
DEB_IT        := dist/$(NAME)-integration_$(VERSION)+$(BUILD)_amd64.deb
DEB_SCHEMA    := dist/$(NAME)-schema_$(VERSION)+$(BUILD)_amd64.deb
DEB_INDEX     := dist/$(NAME)-index_$(VERSION)+$(BUILD)_amd64.deb
EXECUTABLES   := $(NAME) $(NAME)-integration $(NAME)-schema $(NAME)-index
DOCKER_USER    ?= quay.io/wire
DOCKER_TAG     ?= local
INTEGRATION_USE_NGINZ ?= 1

guard-%:
	@ if [ "${${*}}" = "" ]; then \
	      echo "Environment variable $* not set"; \
	    exit 1; \
	fi

default: fast

init:
	mkdir -p ../../dist

.PHONY: install
install: init
	stack install . --pedantic --test --bench --no-run-benchmarks --local-bin-path=dist

.PHONY: fast
fast: init
	stack install . --pedantic --test --bench --no-run-benchmarks --local-bin-path=dist --fast $(WIRE_STACK_OPTIONS)

.PHONY: clean
clean:
	stack clean $(NAME)

.PHONY: compile
compile:
	stack build . --fast --test --bench --no-run-benchmarks --no-copy-bins

.PHONY: i
i:
	INTEGRATION_USE_NGINZ=$(INTEGRATION_USE_NGINZ) ../integration.sh $(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml $(WIRE_INTEGRATION_TEST_OPTIONS)

.PHONY: i-aws
i-aws:
	INTEGRATION_USE_REAL_AWS=1 INTEGRATION_USE_NGINZ=$(INTEGRATION_USE_NGINZ) ../integration.sh $(EXE_IT) -s $(NAME).integration-aws.yaml -i ../integration.yaml $(WIRE_INTEGRATION_TEST_OPTIONS)

.PHONY: i-federation
i-federation:
	INTEGRATION_FEDERATION_TESTS=1 INTEGRATION_USE_NGINZ=$(INTEGRATION_USE_NGINZ) ../integration.sh $(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml -p brig-federation $(WIRE_INTEGRATION_TEST_OPTIONS)

.PHONY: i-list
i-list:
	../integration.sh $(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml -l

i-%:
	INTEGRATION_USE_NGINZ=$(INTEGRATION_USE_NGINZ) ../integration.sh $(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml -p "$*" $(WIRE_INTEGRATION_TEST_OPTIONS)


# Like integration-%, but starts services only once then runs a given test pattern $FLAKE_AMOUNT times until a failure is seen
FLAKE_FILE    ?= /tmp/flake.sh
FLAKE_AMOUNT  ?= 1000
flake-%: fast
	echo 'set -ex' > $(FLAKE_FILE)
	chmod +x $(FLAKE_FILE)
	for i in $$(seq $(FLAKE_AMOUNT)); do \
		echo "echo $$i" >> $(FLAKE_FILE); \
		echo '$(EXE_IT) -s $(NAME).integration.yaml -i ../integration.yaml -p "$*" $(WIRE_INTEGRATION_TEST_OPTIONS)' >> $(FLAKE_FILE); \
	done
	INTEGRATION_USE_NGINZ=$(INTEGRATION_USE_NGINZ) ../integration.sh $(FLAKE_FILE)

.PHONY: integration
integration: fast i

.PHONY: integration-list
integration-list: fast i-list

integration-%: fast
	make "i-$*"

.PHONY: db
db: db-reset

.PHONY: db-reset
db-reset: fast
	$(EXE_SCHEMA) --keyspace $(NAME)_test --replication-factor 1 --reset

.PHONY: db-migrate
db-migrate: fast
	$(EXE_SCHEMA) --keyspace $(NAME)_test --replication-factor 1

.PHONY: index
index: index-reset

.PHONY: index-reset
index-reset: install
	$(EXE_INDEX) reset

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
