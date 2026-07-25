.PHONY: help validate validate-marketplace validate-plugins validate-structure validate-versions check-clean check-branch desktop deploy clean version bump-patch bump-minor bump-major

# Release targets rely on prerequisites running in the listed order
# (check-clean and check-branch must both run before anything writes a
# version file). Parallel make would not guarantee that.
.NOTPARALLEL:

# Get current version from marketplace.json
get-version:
	@jq -r '.version' .claude-plugin/marketplace.json

# Default target
help:
	@echo "Available targets:"
	@echo ""
	@echo "Validation:"
	@echo "  validate           - Run all validation checks for marketplace compliance"
	@echo "  validate-marketplace - Validate marketplace.json schema"
	@echo "  validate-plugins   - Validate all plugin.json manifests"
	@echo "  validate-structure - Validate directory structure"
	@echo "  validate-versions  - Check plugin.json versions match marketplace.json"
	@echo ""
	@echo "Packaging:"
	@echo "  desktop            - Create .zip files for Claude Desktop"
	@echo ""
	@echo "Version Management:"
	@echo "  version            - Show current version"
	@echo "  bump-patch         - Increment patch version (1.0.0 -> 1.0.1)"
	@echo "  bump-minor         - Increment minor version (1.0.0 -> 1.1.0)"
	@echo "  bump-major         - Increment major version (1.0.0 -> 2.0.0)"
	@echo ""
	@echo "Deployment:"
	@echo "  deploy             - Deploy to GitHub (auto-increments patch version)"
	@echo "  deploy-minor       - Deploy with minor version bump"
	@echo "  deploy-major       - Deploy with major version bump"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean              - Remove build artifacts"

# Show current version
version:
	@echo "Current version: $$(jq -r '.version' .claude-plugin/marketplace.json)"

# Bump patch version (1.0.0 -> 1.0.1)
bump-patch:
	@CURRENT=$$(jq -r '.version' .claude-plugin/marketplace.json); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	PATCH=$$(echo $$CURRENT | cut -d. -f3); \
	NEW_PATCH=$$((PATCH + 1)); \
	NEW_VERSION="$$MAJOR.$$MINOR.$$NEW_PATCH"; \
	echo "Bumping version: $$CURRENT -> $$NEW_VERSION"; \
	jq --arg v "$$NEW_VERSION" '.version = $$v' .claude-plugin/marketplace.json > .claude-plugin/marketplace.json.tmp && \
	mv .claude-plugin/marketplace.json.tmp .claude-plugin/marketplace.json; \
	echo "✅ Marketplace version is now $$NEW_VERSION (per-plugin versions untouched)"

# Bump minor version (1.0.0 -> 1.1.0)
bump-minor:
	@CURRENT=$$(jq -r '.version' .claude-plugin/marketplace.json); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	NEW_MINOR=$$((MINOR + 1)); \
	NEW_VERSION="$$MAJOR.$$NEW_MINOR.0"; \
	echo "Bumping version: $$CURRENT -> $$NEW_VERSION"; \
	jq --arg v "$$NEW_VERSION" '.version = $$v' .claude-plugin/marketplace.json > .claude-plugin/marketplace.json.tmp && \
	mv .claude-plugin/marketplace.json.tmp .claude-plugin/marketplace.json; \
	echo "✅ Marketplace version is now $$NEW_VERSION (per-plugin versions untouched)"

# Bump major version (1.0.0 -> 2.0.0)
bump-major:
	@CURRENT=$$(jq -r '.version' .claude-plugin/marketplace.json); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	NEW_MAJOR=$$((MAJOR + 1)); \
	NEW_VERSION="$$NEW_MAJOR.0.0"; \
	echo "Bumping version: $$CURRENT -> $$NEW_VERSION"; \
	jq --arg v "$$NEW_VERSION" '.version = $$v' .claude-plugin/marketplace.json > .claude-plugin/marketplace.json.tmp && \
	mv .claude-plugin/marketplace.json.tmp .claude-plugin/marketplace.json; \
	echo "✅ Marketplace version is now $$NEW_VERSION (per-plugin versions untouched)"

# Validate marketplace.json schema
validate-marketplace:
	@echo "==> Validating marketplace.json..."
	@if [ ! -f .claude-plugin/marketplace.json ]; then \
		echo "❌ ERROR: .claude-plugin/marketplace.json not found"; \
		exit 1; \
	fi
	@jq empty .claude-plugin/marketplace.json || (echo "❌ ERROR: Invalid JSON in marketplace.json"; exit 1)
	@jq -e '.name' .claude-plugin/marketplace.json > /dev/null || (echo "❌ ERROR: Missing required field: name"; exit 1)
	@jq -e '.owner' .claude-plugin/marketplace.json > /dev/null || (echo "❌ ERROR: Missing required field: owner"; exit 1)
	@jq -e '.plugins' .claude-plugin/marketplace.json > /dev/null || (echo "❌ ERROR: Missing required field: plugins"; exit 1)
	@jq -e '.plugins | if type == "array" then true else false end' .claude-plugin/marketplace.json > /dev/null || (echo "❌ ERROR: plugins must be an array"; exit 1)
	@echo "✅ marketplace.json is valid"

# Validate all plugin.json manifests
validate-plugins:
	@echo "==> Validating plugin manifests..."
	@for plugin_json in $$(find plugins -name "plugin.json" -path "*/.claude-plugin/plugin.json"); do \
		echo "  Checking $$plugin_json..."; \
		jq empty $$plugin_json || (echo "❌ ERROR: Invalid JSON in $$plugin_json"; exit 1); \
		jq -e '.name' $$plugin_json > /dev/null || (echo "❌ ERROR: Missing required field 'name' in $$plugin_json"; exit 1); \
		if jq -e '.commands' $$plugin_json > /dev/null 2>&1; then \
			jq -e '.commands | if type == "string" then startswith("./") else if type == "array" then all(startswith("./")) else false end end' $$plugin_json > /dev/null || (echo "❌ ERROR: Component paths must start with ./ in $$plugin_json"; exit 1); \
		fi; \
		echo "  ✅ $$plugin_json is valid"; \
	done
	@echo "✅ All plugin manifests are valid"

# Validate directory structure compliance
validate-structure:
	@echo "==> Validating directory structure..."
	@if [ ! -d .claude-plugin ]; then \
		echo "❌ ERROR: .claude-plugin/ directory not found at root"; \
		exit 1; \
	fi
	@if [ ! -d plugins ]; then \
		echo "❌ ERROR: plugins/ directory not found"; \
		exit 1; \
	fi
	@if [ ! -f README.md ]; then \
		echo "⚠️  WARNING: README.md not found at root"; \
	fi
	@if [ ! -f LICENSE ]; then \
		echo "⚠️  WARNING: LICENSE not found at root"; \
	fi
	@for plugin_dir in plugins/*; do \
		if [ -d "$$plugin_dir" ]; then \
			plugin_name=$$(basename $$plugin_dir); \
			echo "  Checking $$plugin_name structure..."; \
			if [ ! -f "$$plugin_dir/.claude-plugin/plugin.json" ]; then \
				echo "❌ ERROR: Missing $$plugin_dir/.claude-plugin/plugin.json"; \
				exit 1; \
			fi; \
			if [ -d "$$plugin_dir/skills" ]; then \
				for skill_dir in $$plugin_dir/skills/*; do \
					if [ -d "$$skill_dir" ]; then \
						if [ ! -f "$$skill_dir/SKILL.md" ]; then \
							echo "❌ ERROR: Missing SKILL.md in $$skill_dir"; \
							exit 1; \
						fi; \
					fi; \
				done; \
			fi; \
			echo "  ✅ $$plugin_name structure is valid"; \
		fi; \
	done
	@echo "✅ Directory structure is compliant"

# Validate that every plugin's version matches its marketplace.json entry,
# and that the two plugin lists agree in both directions. bump-* no longer
# force-syncs these, so this check is what keeps the hand-maintained
# invariant honest.
validate-versions:
	@echo "==> Validating plugin version parity..."
	@FAILED=0; \
	for plugin_dir in plugins/*; do \
		[ -d "$$plugin_dir" ] || continue; \
		manifest="$$plugin_dir/.claude-plugin/plugin.json"; \
		name=$$(jq -r '.name' "$$manifest"); \
		plugin_version=$$(jq -r '.version // ""' "$$manifest"); \
		market_version=$$(jq -r --arg n "$$name" '.plugins[] | select(.name == $$n) | .version // ""' .claude-plugin/marketplace.json); \
		if [ -z "$$market_version" ]; then \
			echo "❌ ERROR: $$name is not registered in marketplace.json"; \
			FAILED=1; \
		elif [ "$$plugin_version" != "$$market_version" ]; then \
			echo "❌ ERROR: $$name version mismatch: plugin.json=$$plugin_version marketplace.json=$$market_version"; \
			FAILED=1; \
		else \
			echo "  ✅ $$name $$plugin_version"; \
		fi; \
	done; \
	for name in $$(jq -r '.plugins[].name' .claude-plugin/marketplace.json); do \
		if [ ! -d "plugins/$$name" ]; then \
			echo "❌ ERROR: marketplace.json lists $$name but plugins/$$name does not exist"; \
			FAILED=1; \
		fi; \
	done; \
	if [ $$FAILED -ne 0 ]; then exit 1; fi; \
	echo "✅ All plugin versions match their marketplace entries"

# Run all validations
validate: validate-marketplace validate-plugins validate-structure validate-versions
	@echo ""
	@echo "================================"
	@echo "✅ All validations passed!"
	@echo "Repository is Claude Code marketplace compliant"
	@echo "================================"

# Package skills as .zip files for Claude Desktop
desktop:
	@echo "==> Packaging skills for Claude Desktop..."
	@rm -rf dist && mkdir -p dist
	@ROOT_DIR=$$(pwd); \
	for plugin_dir in plugins/*; do \
		if [ -d "$$plugin_dir/skills" ]; then \
			plugin_name=$$(basename $$plugin_dir); \
			echo "  Packaging skills from $$plugin_name..."; \
			for skill_dir in $$plugin_dir/skills/*; do \
				if [ -d "$$skill_dir" ]; then \
					skill_name=$$(basename $$skill_dir); \
					echo "    Creating $$skill_name.zip..."; \
					(cd "$$skill_dir" && zip -r "$$ROOT_DIR/dist/$$skill_name.zip" . -x "*.git*" "*.DS_Store" "**/__pycache__/*" "*.pyc"); \
				fi; \
			done; \
		fi; \
	done
	@echo "✅ Desktop packages created in dist/"
	@ls -lh dist/*.zip 2>/dev/null || true

# Refuse to start a release from a dirty tree. This runs BEFORE any bump
# target writes a version file, so an aborted release never leaves a
# half-applied version behind.
check-clean:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "❌ ERROR: Working directory is not clean. Commit or stash first."; \
		git status --short; \
		exit 1; \
	fi

# Confirm before releasing from a branch other than main.
check-branch:
	@BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$BRANCH" != "main" ]; then \
		echo "⚠️  WARNING: Not on main branch (current: $$BRANCH)"; \
		printf "Continue? [y/N] "; \
		read REPLY; \
		case "$$REPLY" in \
			[Yy]*) ;; \
			*) echo "Deployment cancelled"; exit 1 ;; \
		esac; \
	fi

# Commit the marketplace version bump, tag, and push.
# Only marketplace.json is staged: bump-* no longer writes plugin.json, so
# anything else being dirty is an unrelated edit and check-clean already
# rejected it.
define release_and_push
	VERSION=$$(jq -r '.version' .claude-plugin/marketplace.json); \
	echo "==> Deploying v$$VERSION..."; \
	git add .claude-plugin/marketplace.json; \
	git commit -m "Bump version to $$VERSION"; \
	git tag -a "v$$VERSION" -m "Release v$$VERSION"; \
	git push origin main; \
	git push origin "v$$VERSION"; \
	echo "✅ Deployed v$$VERSION"
endef

# Deploy to GitHub with patch version bump
deploy: check-clean check-branch bump-patch validate desktop
	@$(release_and_push); \
	echo ""; \
	echo "================================"; \
	echo "Next steps:"; \
	echo "  1. Create GitHub release: https://github.com/apresai/apresai-skills/releases/new?tag=v$$(jq -r '.version' .claude-plugin/marketplace.json)"; \
	echo "  2. Upload dist/*.zip files to the release"; \
	echo "  3. Users can install with: /plugin marketplace add apresai/apresai-skills"; \
	echo "================================"

# Deploy with minor version bump
deploy-minor: check-clean check-branch bump-minor validate desktop
	@$(release_and_push)

# Deploy with major version bump
deploy-major: check-clean check-branch bump-major validate desktop
	@$(release_and_push)

# Clean build artifacts
clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf dist
	@find . -type f -name "*.pyc" -delete
	@find . -type d -name "__pycache__" -delete
	@find . -type f -name ".DS_Store" -delete
	@echo "✅ Cleaned"
