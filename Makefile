# Convenience targets. Nothing here needs root.
.PHONY: help test test-e2e test-pty test-ps test-guest test-all check build clean

help:
	@echo "make test     run the smoke suite (skips the two module builds)"
	@echo "make test-e2e Deploy end-to-end with a fake ssh (needs pwsh)"
	@echo "make test-pty prove a sudo prompt stays visible through the pty helper"
	@echo "make test-ps  unit-test the PowerShell helpers (MMIO parsing, discovery)"
	@echo "make test-guest run every guest command under set -u; catch unbound locals"
	@echo "make test-all run everything, including download + compile of both branches"
	@echo "make check    syntax only (bash -n, py_compile, PowerShell parse if pwsh exists)"
	@echo "make build    build dxgkrnl for the running kernel into ~/.cache/gpupv"
	@echo "make clean    remove build artefacts and __pycache__"

test:
	bash tests/smoke.sh --no-build

test-e2e:
	bash tests/e2e_deploy.sh

test-pty:
	bash tests/pty_prompt_probe.sh

test-ps:
	pwsh -NoProfile -File tests/ps_units.ps1

test-guest:
	bash tests/guest_shellcheck.sh

test-all:
	bash tests/smoke.sh

check:
	@for f in gpupv.sh gpupv-fnos.sh lib/*.sh tests/*.sh tools/*.sh; do bash -n $$f && echo "ok  $$f"; done
	@bash tests/pty_prompt_probe.sh | tail -2
	@bash tests/guest_shellcheck.sh | tail -2
	@python3 -m py_compile src/http_put_server.py && echo "ok  src/http_put_server.py"
	@if command -v pwsh >/dev/null 2>&1; then \
		pwsh -NoProfile -File tests/parse_ps1.ps1 -Path gpupv-windows.ps1 && \
		pwsh -NoProfile -File tests/parse_ps1.ps1 -Path tests/deploy_cmds.ps1 && \
		pwsh -NoProfile -File tests/ps_units.ps1; \
	else echo "skip gpupv-windows.ps1 (no pwsh installed)"; fi

build:
	./gpupv.sh module build

clean:
	rm -rf src/__pycache__
