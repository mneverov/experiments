export KUBECONFIG := env/kubeconfig.yaml

build:
	go build -o bin/memtest .

image:
	docker build -t memtest:dev .

setup-env: image
	./env/setup.sh

teardown-env:
	./env/teardown.sh

# Reload the image after changing main.go; the next experiment run uses it.
load-image: image
	kind load docker-image memtest:dev --name memtest2026

grafana:
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

prometheus:
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090

# make experiment-<default|free-os-memory|madv-free|gomemlimit-800|gomemlimit-400>
experiment-%:
	./env/run-experiment.sh $*

.PHONY: build image setup-env teardown-env load-image grafana prometheus experiments

# All modes and scenarios, about 2 hours.
experiments:
	for s in late early; do for m in default free-os-memory madv-free gomemlimit-800 gomemlimit-400; do ./env/run-experiment.sh $$m $$s || exit 1; done; done
