# Commands from AGENTS.md. Neither target needs AWS credentials.

ROOTS := bootstrap organization

.PHONY: test lint

# terraform validate for every Terraform root.
test:
	@set -e; for root in $(ROOTS); do \
	  echo "==> $$root"; \
	  terraform -chdir=$$root init -backend=false -input=false -no-color >/dev/null; \
	  terraform -chdir=$$root validate -no-color; \
	done

# terraform fmt -check for the whole repo.
lint:
	terraform fmt -check -recursive
