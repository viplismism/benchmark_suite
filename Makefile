.PHONY: help setup litellm litellm-start litellm-stop litellm-status litellm-logs litellm-tail \
		tau-bench terminal-bench terminal-bench-2 terminal-bench-resume terminal-bench-list clean docker-clean

help:
	@echo "═══════════════════════════════════════════════════════════════════════"
	@echo "  Benchmark Suite"
	@echo "═══════════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  LiteLLM Proxy:"
	@echo "    make litellm          - Start proxy (foreground, with logs)"
	@echo "    make litellm-start    - Start proxy (background)"
	@echo "    make litellm-stop     - Stop proxy"
	@echo "    make litellm-status   - Check proxy status"
	@echo "    make litellm-logs     - View recent logs"
	@echo "    make litellm-tail     - Follow logs in real-time"
	@echo ""
	@echo "  Benchmarks:"
	@echo "    make tau-bench        - Run τ-Bench evaluation"
	@echo "    make terminal-bench   - Run Terminal-Bench evaluation"
	@echo "    make terminal-bench-2 - Run Terminal-Bench 2.0 evaluation"
	@echo "    make terminal-bench-resume CHECKPOINT=<path>"
	@echo "    make terminal-bench-list"
	@echo ""
	@echo "  Utilities:"
	@echo "    make setup            - Setup environment"
	@echo "    make clean            - Clean up Terminal-Bench Docker containers"
	@echo "    make docker-clean     - Remove ALL Docker containers, images, volumes"
	@echo ""
	@echo "  Configuration: Edit config.env for model/endpoint settings"
	@echo "═══════════════════════════════════════════════════════════════════════"

setup:
	@chmod +x benchmarks/*.sh 2>/dev/null || true
	@mkdir -p benchmark_results
	@echo "✓ Setup complete"

LITELLM_PORT := 8001
LITELLM_CONFIG := litellm_config.yaml
LITELLM_LOG := .litellm.log
LITELLM_PID := .litellm.pid
LITELLM_KEY := sk-litellm-proxy-key-123

litellm:
	@echo ""
	@echo "  Starting LiteLLM Proxy on port $(LITELLM_PORT)..."
	@echo ""
	@litellm --config $(LITELLM_CONFIG) --port $(LITELLM_PORT) 2>&1 | \
		grep -E "^(INFO:|LiteLLM: Proxy initialized)"

litellm-start:
	@if curl -s -H "Authorization: Bearer $(LITELLM_KEY)" http://localhost:$(LITELLM_PORT)/health >/dev/null 2>&1; then \
		echo "✓ LiteLLM already running on port $(LITELLM_PORT)"; \
	else \
		echo "Starting LiteLLM on port $(LITELLM_PORT)..."; \
		litellm --config $(LITELLM_CONFIG) --port $(LITELLM_PORT) >> $(LITELLM_LOG) 2>&1 & \
		echo $$! > $(LITELLM_PID); \
		sleep 5; \
		if curl -s -H "Authorization: Bearer $(LITELLM_KEY)" http://localhost:$(LITELLM_PORT)/health >/dev/null 2>&1; then \
			echo "✓ LiteLLM started"; \
			echo "  Models:"; \
			grep "model_name:" $(LITELLM_CONFIG) | sed 's/.*model_name: /    → /' | head -8; \
		else \
			echo "✗ Failed to start"; \
		fi; \
	fi

litellm-stop:
	@pkill -f "litellm.*$(LITELLM_PORT)" 2>/dev/null || true
	@rm -f $(LITELLM_PID)
	@echo "✓ LiteLLM stopped"

litellm-status:
	@if curl -s -H "Authorization: Bearer $(LITELLM_KEY)" http://localhost:$(LITELLM_PORT)/health >/dev/null 2>&1; then \
		echo "✓ LiteLLM running on port $(LITELLM_PORT)"; \
	else \
		echo "✗ LiteLLM not running"; \
	fi

litellm-logs:
	@tail -50 $(LITELLM_LOG) 2>/dev/null | grep -vE "(guardrail|Traceback|TypeError)" | tail -20 || echo "No logs"

litellm-tail:
	@tail -f $(LITELLM_LOG) 2>/dev/null | grep --line-buffered -vE "(guardrail|Traceback|TypeError)" || echo "No logs"

tau-bench: setup
	@cd benchmarks && ./tau_bench.sh

terminal-bench: setup
	@cd benchmarks && ./terminal_bench.sh

terminal-bench-2: setup
	@cd benchmarks && bash terminal_bench_2.sh

terminal-bench-resume: setup
	@if [ -z "$(CHECKPOINT)" ]; then \
		echo "Usage: make terminal-bench-resume CHECKPOINT=<path>"; \
		echo ""; \
		echo "Available checkpoints:"; \
		ls -dt benchmark_results/terminal_bench/*/ 2>/dev/null | head -5 || echo "  None found"; \
	else \
		cd benchmarks && TERMINAL_BENCH_RESUME="$(CHECKPOINT)" ./terminal_bench.sh; \
	fi

terminal-bench-list:
	@echo "Terminal-Bench Checkpoints:"
	@echo "═══════════════════════════════════════════════════════════════════════"
	@for dir in $$(ls -dt benchmark_results/terminal_bench/*/ 2>/dev/null | head -10); do \
		if [ -f "$$dir/summary.json" ]; then \
			info=$$(python3 -c "import json; d=json.load(open('$$dir/summary.json')); print(f\"{d['results']['passed']}/{d['results']['total']} ({d['results']['accuracy']}%) - {d.get('model','?')}\")" 2>/dev/null || echo "?"); \
			echo "  ✓ $$dir"; \
			echo "    $$info"; \
		else \
			echo "  ○ $$dir (incomplete)"; \
		fi; \
	done 2>/dev/null || echo "  No checkpoints found"

clean:
	@echo "Cleaning up Terminal-Bench Docker containers..."
	@docker ps -q --filter "name=tb-" 2>/dev/null | xargs -r docker kill 2>/dev/null || true
	@docker ps -aq --filter "name=tb-" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
	@docker container prune -f 2>/dev/null | grep -v "^$$" || true
	@echo "✓ Done"

docker-clean:
	@echo "═══════════════════════════════════════════════════════════════════════"
	@echo "  Removing ALL Docker resources..."
	@echo "═══════════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "→ Stopping all containers..."
	@docker ps -q 2>/dev/null | xargs -r docker kill 2>/dev/null || true
	@echo "→ Removing all containers..."
	@docker ps -aq 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
	@echo "→ Removing all images..."
	@docker images -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
	@echo "→ Removing all volumes..."
	@docker volume ls -q 2>/dev/null | xargs -r docker volume rm -f 2>/dev/null || true
	@echo "→ Removing all networks (except defaults)..."
	@docker network ls -q --filter "type=custom" 2>/dev/null | xargs -r docker network rm 2>/dev/null || true
	@echo "→ Final prune (build cache, dangling)..."
	@docker system prune -af --volumes 2>/dev/null || true
	@echo ""
	@echo "✓ Docker cleaned completely"