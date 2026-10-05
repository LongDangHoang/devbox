SHELL := /bin/bash
REGION ?= ap-southeast-2
export REGION
TF := terraform -chdir=infra/terraform

# Instance id for NAME by Project tag (terminated excluded); empty if none.
INSTANCE_ID = $$(aws ec2 describe-instances --region $(REGION) \
	--filters Name=tag:Project,Values=$(NAME) Name=instance-state-name,Values=pending,running,stopping,stopped \
	--query 'Reservations[].Instances[].InstanceId' --output text)
NEED_NAME = test -n "$(NAME)" || { echo "error: NAME=<project> is required" >&2; exit 1; }
NEED_ID = [ -n "$$id" ] && [ "$$id" != None ] || { echo "error: no box found for project $(NAME)" >&2; exit 1; }
SESSION = aws ssm start-session --region $(REGION) --target "$$id" \
	--document-name AWS-StartInteractiveCommand --parameters '{"command":["sudo -iu ubuntu"]}'

.DEFAULT_GOAL := help
.PHONY: help new-project secrets login ssh start stop status list retire fmt validate

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

new-project: ## NAME= REPO=owner/name [TYPE=] [DATA_GB=] - add project, terraform apply, commit JSON
	@$(NEED_NAME); test -n "$(REPO)" || { echo "error: REPO=owner/name is required" >&2; exit 1; }
	@set -euo pipefail; f=infra/projects/$(NAME).json; \
	test ! -e "$$f" || { echo "error: $$f already exists" >&2; exit 1; }; \
	gh repo view "$(REPO)" >/dev/null || { echo "error: GitHub repo $(REPO) not found" >&2; exit 1; }; \
	jq -n --arg repo "$(REPO)" --arg t "$(TYPE)" --arg d "$(DATA_GB)" \
	  '{repo:$$repo} + (if $$t != "" then {instance_type:$$t} else {} end) + (if $$d != "" then {data_gb:($$d|tonumber)} else {} end)' > "$$f"; \
	echo "Wrote $$f; running terraform apply (review the plan, answer yes to proceed)"; \
	if $(TF) apply; then \
	  git add "$$f" && git commit -m "Add project $(NAME)" -- "$$f"; \
	else \
	  rm -f "$$f"; echo "apply failed or declined; removed $$f" >&2; exit 1; \
	fi

secrets: ## NAME= - prompt for and set agent token (SSM) + Modal/W&B secrets (gh)
	@$(NEED_NAME); scripts/secrets.sh "$(NAME)"

login: ## NAME= - start box, wait for SSM, open shell as ubuntu (then: claude auth login)
	@$(NEED_NAME)
	@set -euo pipefail; id=$(INSTANCE_ID); $(NEED_ID); \
	echo "Starting $$id if stopped..."; \
	aws ec2 start-instances --region $(REGION) --instance-ids "$$id" >/dev/null; \
	aws ec2 wait instance-running --region $(REGION) --instance-ids "$$id"; \
	echo "Waiting for SSM agent..."; \
	for i in $$(seq 60); do \
	  s=$$(aws ssm describe-instance-information --region $(REGION) --filters Key=InstanceIds,Values="$$id" \
	    --query 'InstanceInformationList[0].PingStatus' --output text); \
	  [ "$$s" = Online ] && break; sleep 5; \
	done; \
	[ "$$s" = Online ] || { echo "error: SSM not online" >&2; exit 1; }; \
	echo "In the session run: claude auth login   (claude.ai login, NOT setup-token)"; \
	$(SESSION)

ssh: ## NAME= - SSM session to the box (no auto-start)
	@$(NEED_NAME)
	@set -euo pipefail; id=$(INSTANCE_ID); $(NEED_ID); $(SESSION)

start: ## NAME= - start the box
	@$(NEED_NAME)
	@set -euo pipefail; id=$(INSTANCE_ID); $(NEED_ID); echo "Starting $$id"; \
	aws ec2 start-instances --region $(REGION) --instance-ids "$$id" --query 'StartingInstances[].CurrentState.Name' --output text

stop: ## NAME= - stop the box
	@$(NEED_NAME)
	@set -euo pipefail; id=$(INSTANCE_ID); $(NEED_ID); echo "Stopping $$id"; \
	aws ec2 stop-instances --region $(REGION) --instance-ids "$$id" --query 'StoppingInstances[].CurrentState.Name' --output text

status: ## NAME= - show box state
	@$(NEED_NAME)
	@set -euo pipefail; id=$(INSTANCE_ID); $(NEED_ID); \
	aws ec2 describe-instances --region $(REGION) --instance-ids "$$id" \
	  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text

list: ## List projects with repo and box state
	@set -euo pipefail; \
	states=$$(aws ec2 describe-instances --region $(REGION) \
	  --filters Name=tag-key,Values=Project Name=instance-state-name,Values=pending,running,stopping,stopped \
	  --query 'Reservations[].Instances[].[Tags[?Key==`Project`]|[0].Value,State.Name]' --output text); \
	printf '%-20s %-35s %s\n' NAME REPO STATE; \
	for f in infra/projects/*.json; do \
	  [ -e "$$f" ] || continue; n=$$(basename "$$f" .json); \
	  s=$$(printf '%s\n' "$$states" | awk -v n="$$n" '$$1==n {print $$2}'); \
	  printf '%-20s %-35s %s\n' "$$n" "$$(jq -r .repo "$$f")" "$${s:-none}"; \
	done

retire: ## NAME= - destroy a project's box/data volume/GitHub settings (final snapshot kept)
	@$(NEED_NAME); scripts/retire.sh "$(NAME)"

fmt: ## terraform fmt -recursive
	terraform -chdir=infra/terraform fmt -recursive

validate: ## terraform init -backend=false && validate
	$(TF) init -backend=false && $(TF) validate
