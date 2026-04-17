.PHONY: help resolve build test test-coverage lint app app-universal run clean open

help:
	@echo "Pulse — common tasks"
	@echo ""
	@echo "  make resolve        Resolve Swift Package dependencies"
	@echo "  make build          swift build (debug)"
	@echo "  make test           swift test"
	@echo "  make test-coverage  swift test with code coverage enabled"
	@echo "  make lint           Run scripts/lint.sh"
	@echo "  make app            Build ad-hoc-signed dist/Pulse.app (native arch)"
	@echo "  make app-universal  Same, arm64 + x86_64 universal binary"
	@echo "  make run            Build + launch dist/Pulse.app"
	@echo "  make open           Open Package.swift in Xcode"
	@echo "  make clean          Remove .build/ and dist/"
	@echo ""

resolve:
	swift package resolve

build:
	swift build

test:
	swift test --parallel

test-coverage:
	swift test --parallel --enable-code-coverage

lint:
	bash scripts/lint.sh

app:
	bash scripts/package.sh

app-universal:
	UNIVERSAL=1 bash scripts/package.sh

run: app
	open dist/Pulse.app

open:
	open Package.swift

clean:
	rm -rf .build dist
