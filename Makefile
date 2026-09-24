# Usage:
#   make init ENV=tokyo      # terraform init with the per-region backend config
#   make plan ENV=tokyo
#   make apply ENV=tokyo
#   make fmt / make validate / make lint / make test
#
# ENV maps to envs/prod/<ENV>.tfvars and envs/prod/backend-<ENV>.hcl.

STACK   ?= stacks/regional
ENV     ?= tokyo
TFVARS  := $(abspath envs/prod/$(ENV).tfvars)
BACKEND := $(abspath envs/prod/backend-$(ENV).hcl)
TF      := terraform -chdir=$(STACK)

.PHONY: init plan apply destroy fmt validate lint test clean

init:
	$(TF) init -reconfigure -backend-config=$(BACKEND)

plan: init
	$(TF) plan -var-file=$(TFVARS) -out=$(ENV).tfplan

apply:
	$(TF) apply $(ENV).tfplan

destroy: init
	$(TF) destroy -var-file=$(TFVARS)

fmt:
	terraform fmt -recursive

validate:
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate
	@for m in modules/*/; do \
	  terraform -chdir=$$m init -backend=false -input=false >/dev/null && terraform -chdir=$$m validate || exit 1; \
	done

lint:
	tflint --init
	tflint --recursive --config=$(CURDIR)/.tflint.hcl

test:
	python3 -m pytest -q src/lambda/tests

clean:
	find . -name '*.tfplan' -delete
	rm -rf build
