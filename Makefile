# Every tool runs in a pinned container, so the only local requirement is
# Docker, and CI runs exactly the same commands.

SLOTH       := ghcr.io/slok/sloth:v0.16.0
PROMTOOL    := prom/prometheus:v3.15.0
YQ          := mikefarah/yq:4.54.1
KUBECONFORM := ghcr.io/yannh/kubeconform:v0.8.0
KUSTOMIZE   := registry.k8s.io/kustomize/kustomize:v5.8.1
HELM        := alpine/helm:3.22.0
K8S_VERSION := 1.36.0

DOCKER := docker run --rm -u $$(id -u):$$(id -g) -v $(CURDIR):/work -w /work

SLO_SPECS := $(wildcard slos/*.yaml)
SCENARIO  ?= latency

.DEFAULT_GOAL := help
.PHONY: help generate check-generated rules test validate check gameday

help: ## Show the available targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

generate: ## Generate Prometheus rules from the SLO specs in slos/
	@for spec in $(SLO_SPECS); do \
	  out=manifests/sre/slo-rules/$$(basename $$spec); mkdir -p $$(dirname $$out); \
	  echo "$$spec -> $$out"; \
	  $(DOCKER) $(SLOTH) generate -i $$spec -o $$out || exit 1; \
	done

check-generated: generate ## Fail if the committed rules differ from what the specs generate
	@git diff --exit-code -- manifests/sre/slo-rules/ || \
	  (echo "Generated rules are out of date: run 'make generate' and commit the result." && exit 1)

rules: ## Extract plain rule files from the PrometheusRule manifests, for promtool
	@mkdir -p build/rules
	@for f in manifests/sre/slo-rules/*.yaml; do \
	  $(DOCKER) $(YQ) '.spec' $$f > build/rules/$$(basename $$f) || exit 1; \
	done

test: rules ## Check the rules and run the alert unit tests in tests/
	$(DOCKER) --entrypoint promtool $(PROMTOOL) check rules build/rules/*.yaml
	$(DOCKER) --entrypoint promtool $(PROMTOOL) test rules tests/*.yaml

# Chaos Mesh publishes no JSON schemas, so its two kinds are skipped here. The
# game day applies them to a real cluster on every run, which checks them fully.
validate: ## Render the manifests and the apps chart, then validate them against the Kubernetes and CRD schemas
	@mkdir -p build
	$(DOCKER) $(KUSTOMIZE) build manifests/sre > build/sre.yaml
	$(DOCKER) $(HELM) template sre apps > build/apps.yaml
	$(DOCKER) $(KUBECONFORM) -strict -summary -kubernetes-version $(K8S_VERSION) \
	  -skip NetworkChaos,PodChaos \
	  -schema-location default \
	  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
	  build/sre.yaml build/apps.yaml chaos/ load/

check: check-generated test validate ## Everything CI runs before the end-to-end game day

gameday: ## Run a game day against a running cluster: SCENARIO=latency|outage|pod-kill
	scripts/gameday.sh $(SCENARIO)
