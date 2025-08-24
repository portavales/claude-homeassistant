# Home Assistant Configuration Management Makefile

# ==== Configuration ====
HA_HOST = homeassistant
HA_USER = root
HA_REMOTE_PATH = /config/
LOCAL_CONFIG_PATH = config/

BACKUP_DIR = backups
VENV_PATH = .venv
TOOLS_PATH = tools
RSYNC_EXCLUDES = .rsyncignore

# ==== Colors ====
GREEN = \033[0;32m
YELLOW = \033[1;33m
RED = \033[0;31m
NC = \033[0m # No Color

.PHONY: help pull push validate backup clean setup test status entities \
        dry-run-push dry-run-pull check-setup pull-registries pull-storage

# ==== Default target ====
help:
	@echo "$(GREEN)Home Assistant Configuration Management$(NC)"
	@echo ""
	@echo "Available commands:"
	@echo "  $(YELLOW)pull$(NC)           - Pull latest config from Home Assistant"
	@echo "  $(YELLOW)push$(NC)           - Push local config to Home Assistant (with validation)"
	@echo "  $(YELLOW)dry-run-push$(NC)   - Preview what would be pushed"
	@echo "  $(YELLOW)dry-run-pull$(NC)   - Preview what would be pulled"
	@echo "  $(YELLOW)validate$(NC)       - Run all validation tests (auto-pulls registries if missing)"
	@echo "  $(YELLOW)pull-registries$(NC)- Pull minimal HA registries used by the reference validator"
	@echo "  $(YELLOW)backup$(NC)         - Create timestamped backup of LOCAL config/"
	@echo "  $(YELLOW)setup$(NC)          - Set up Python environment and dependencies"
	@echo "  $(YELLOW)test$(NC)           - Alias for validate"
	@echo "  $(YELLOW)status$(NC)         - Show configuration status and entity counts"
	@echo "  $(YELLOW)entities$(NC)       - Explore entities (ARGS='--domain light', '--area \"Kitchen\"', etc.)"
	@echo "  $(YELLOW)clean$(NC)          - Clean up temporary files and caches"

# ==== Rsync helpers (non-destructive by default) ====
# NOTE: We do NOT use --delete by default to avoid removing runtime folders on the server.

# Pull configuration from Home Assistant
pull:
	@echo "$(GREEN)Pulling configuration from Home Assistant...$(NC)"
	@rsync -avz --exclude-from=$(RSYNC_EXCLUDES) \
		$(HA_HOST):$(HA_REMOTE_PATH) $(LOCAL_CONFIG_PATH)
	@echo "$(GREEN)Configuration pulled successfully!$(NC)"
	@echo "$(YELLOW)Running validation to ensure integrity...$(NC)"
	@$(MAKE) validate

# Push configuration to Home Assistant (with pre-validation)
push:
	@echo "$(GREEN)Validating configuration before push...$(NC)"
	@$(MAKE) validate
	@echo "$(GREEN)Validation passed! Pushing to Home Assistant...$(NC)"
	@rsync -avz --exclude-from=$(RSYNC_EXCLUDES) \
		$(LOCAL_CONFIG_PATH) $(HA_HOST):$(HA_REMOTE_PATH)
	@echo "$(GREEN)Configuration pushed successfully!$(NC)"
	@echo "$(YELLOW)Remember to reload Automations/YAML or restart Home Assistant if needed.$(NC)"

# Dry-run preview: what would be pushed
dry-run-push:
	@echo "$(YELLOW)[DRY RUN] Preview of push to Home Assistant$(NC)"
	@rsync -avzn --exclude-from=$(RSYNC_EXCLUDES) \
		$(LOCAL_CONFIG_PATH) $(HA_HOST):$(HA_REMOTE_PATH)

# Dry-run preview: what would be pulled
dry-run-pull:
	@echo "$(YELLOW)[DRY RUN] Preview of pull from Home Assistant$(NC)"
	@rsync -avzn --exclude-from=$(RSYNC_EXCLUDES) \
		$(HA_HOST):$(HA_REMOTE_PATH) $(LOCAL_CONFIG_PATH)

# ==== Minimal registries for reference validation ====
pull-registries:
	@mkdir -p $(LOCAL_CONFIG_PATH).storage
	@rsync -avz $(HA_HOST):$(HA_REMOTE_PATH).storage/core.entity_registry $(LOCAL_CONFIG_PATH).storage/ 2>/dev/null || true
	@rsync -avz $(HA_HOST):$(HA_REMOTE_PATH).storage/core.device_registry $(LOCAL_CONFIG_PATH).storage/ 2>/dev/null || true
	@rsync -avz $(HA_HOST):$(HA_REMOTE_PATH).storage/core.area_registry   $(LOCAL_CONFIG_PATH).storage/ 2>/dev/null || true

# Alias for convenience (some folks expect 'pull-storage')
pull-storage: pull-registries

# ==== Validation ====
validate: check-setup
	@if [ ! -f "$(LOCAL_CONFIG_PATH).storage/core.entity_registry" ] || [ ! -f "$(LOCAL_CONFIG_PATH).storage/core.device_registry" ]; then \
		echo "$(YELLOW)Entity/device registries missing locally; pulling minimal registries for validation...$(NC)"; \
		$(MAKE) pull-registries; \
	fi
	@echo "$(GREEN)Running Home Assistant configuration validation...$(NC)"
	@. $(VENV_PATH)/bin/activate && python $(TOOLS_PATH)/run_tests.py

# Alias
test: validate

# ==== Backups ====
backup:
	@echo "$(GREEN)Creating backup of current LOCAL configuration...$(NC)"
	@mkdir -p $(BACKUP_DIR)
	@timestamp=$$(date +%Y%m%d_%H%M%S); \
	backup_name="$(BACKUP_DIR)/ha_config_$$timestamp"; \
	tar -czf "$$backup_name.tar.gz" $(LOCAL_CONFIG_PATH); \
	echo "$(GREEN)Backup created: $$backup_name.tar.gz$(NC)"

# ==== Setup & Utilities ====
setup:
	@echo "$(GREEN)Setting up Python environment...$(NC)"
	@python3 -m venv $(VENV_PATH)
	@. $(VENV_PATH)/bin/activate && pip install --upgrade pip
	@. $(VENV_PATH)/bin/activate && pip install homeassistant voluptuous pyyaml jsonschema requests
	@echo "$(GREEN)Setup complete!$(NC)"

status: check-setup
	@echo "$(GREEN)Home Assistant Configuration Status$(NC)"
	@echo "=================================="
	@echo "Config directory: $(LOCAL_CONFIG_PATH)"
	@echo "Remote host: $(HA_HOST)"
	@echo ""
	@if [ -f "$(LOCAL_CONFIG_PATH)configuration.yaml" ]; then \
		echo "$(GREEN)✓$(NC) configuration.yaml found"; \
	else \
		echo "$(RED)✗$(NC) configuration.yaml missing"; \
	fi
	@if [ -d "$(LOCAL_CONFIG_PATH).storage" ]; then \
		echo "$(GREEN)✓$(NC) .storage present (for reference validation)"; \
	else \
		echo "$(YELLOW)!$(NC) .storage not present"; \
	fi
	@echo ""
	@echo "$(YELLOW)Entity Summary (sample):$(NC)"
	@. $(VENV_PATH)/bin/activate && python $(TOOLS_PATH)/reference_validator.py 2>/dev/null | grep "Examples:" -A 1 -B 1 | head -20

entities: check-setup
	@echo "$(GREEN)Home Assistant Entity Explorer$(NC)"
	@echo "  e.g.: make entities ARGS='--domain light'  or  ARGS='--area \"Living Room\"'"
	@. $(VENV_PATH)/bin/activate && python $(TOOLS_PATH)/entity_explorer.py $(ARGS)

clean:
	@echo "$(GREEN)Cleaning up temporary files...$(NC)"
	@find . -name "*.pyc" -delete
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@find . -name "*.log" -delete 2>/dev/null || true
	@echo "$(GREEN)Cleanup complete!$(NC)"

check-setup:
	@if [ ! -d "$(VENV_PATH)" ]; then \
		echo "$(RED)Python environment not found. Run 'make setup' first.$(NC)"; \
		exit 1; \
	fi
	@if [ ! -f "$(TOOLS_PATH)/run_tests.py" ]; then \
		echo "$(RED)Validation tools not found (expected in $(TOOLS_PATH)).$(NC)"; \
		exit 1; \
	fi

# ==== Optional STRICT MIRROR MODE (use with caution) ====
#STRICT_DELETE = --delete
#RSYNC_DELETE_FLAG = $(STRICT_DELETE)
