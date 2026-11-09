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

# All runs in env/common.sh at once, one apps node each: about 15 min.
experiments:
	./env/run-experiments.sh

# One run on its apps node, e.g. make experiment-madv-free-late
experiment-%:
	./env/run-experiments.sh $*

.PHONY: build image setup-env teardown-env load-image grafana prometheus experiments
