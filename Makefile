# 常用操作。运行 make 或 make help 查看全部目标。
.DEFAULT_GOAL := help
SSH_PORT := $(shell grep -E '^DEVBOX_SSH_PORT=' .env 2>/dev/null | cut -d= -f2)

help: ## 列出全部目标
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

init: ## 首次部署（可重复运行）
	./scripts/init.sh
up: ## 启动或应用 .env 的修改
	docker compose up -d
	./scripts/sync-secrets.sh
down: ## 停止全部服务（数据保留）
	docker compose down
restart: ## 重启网关（修改 config.yaml 或 SOUL.md 后）
	docker exec hermes hermes gateway restart
logs: ## 查看网关日志
	docker compose logs -f --tail=200 hermes
ps: ## 查看容器状态
	docker compose ps
check: ## 自检
	./scripts/check.sh
check-llm: ## 自检，并实际调用一次模型（消耗少量 token）
	./scripts/check.sh --llm
doctor: ## 自检，并运行 hermes doctor
	./scripts/check.sh --doctor
configure: ## 重新写入推荐配置和 .env 中的模型设置
	./scripts/configure.sh
model: ## 交互选择模型和 provider
	@if grep -qE '^STACK_MODEL_PROVIDER=.+' .env 2>/dev/null; then \
	  echo "提示：.env 设置了 STACK_MODEL_PROVIDER，下次 make configure 会用 .env 覆盖这里的选择。"; fi
	docker exec -it hermes hermes model
cli: ## 在服务器终端里和 Agent 对话
	docker exec -it hermes hermes
config: ## 编辑 Hermes 的 config.yaml
	docker exec -it hermes hermes config edit
shell: ## 以 dev 用户进入 devbox
	ssh -p $(or $(SSH_PORT),2222) -o StrictHostKeyChecking=accept-new dev@127.0.0.1
backup: ## 备份
	./scripts/backup.sh
update: ## 备份后升级 Hermes 和 devbox
	./scripts/update.sh

.PHONY: help init up down restart logs ps check check-llm doctor configure model cli config shell backup update
