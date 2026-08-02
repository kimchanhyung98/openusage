.PHONY: help check init

.DEFAULT_GOAL := help

NPM_CACHE ?= /tmp/openusage-npm-cache

help: ## 사용 가능한 명령어 목록 출력
	@awk 'BEGIN {FS = ":.*##"; printf "\\n사용법:\\n  make \\033[36m<target>\\033[0m\\n\\n명령어:\\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \\033[36m%-15s\\033[0m %s\\n", $$1, $$2 } /^##@/ { printf "\\n\\033[1m%s\\033[0m\\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

check: ## Swift 빌드와 테스트 실행
	swift build
	swift test

init: ## 로컬 개발 환경 설정
	@if ! command -v swift >/dev/null 2>&1; then \\
		echo "[init] Swift not found"; \\
		exit 1; \\
	fi
	@if ! command -v npm >/dev/null 2>&1; then \\
		echo "[init] npm not found"; \\
		exit 1; \\
	fi
	@NPM_CONFIG_CACHE="$(NPM_CACHE)" npm ci
	@swift package resolve
	@echo "[init] development environment ready"
