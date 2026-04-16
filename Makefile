.PHONY: help resolve build test test-coverage lint clean open

help:
	@echo "Pulse — common tasks"
	@echo ""
	@echo "  make resolve        Resolve Swift Package dependencies"
	@echo "  make build          swift build (debug)"
	@echo "  make test           swift test"
	@echo "  make test-coverage  swift test with code coverage enabled"
	@echo "  make lint           Run scripts/lint.sh"
	@echo "  make open           Open Package.swift in Xcode"
	@echo "  make clean          Remove .build/"
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

open:
	open Package.swift

clean:
	rm -rf .build
