#!/usr/bin/env bash
# 一键部署/重新部署: 停旧 → 拉新代码 → 起新
# 用法 (在 /opt/teamgram-server 目录下): bash deploy.sh

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

echo ">>> [1/5] 停旧容器(business + env)"
docker compose down --remove-orphans 2>/dev/null || true
docker compose -f docker-compose-env.yaml down --remove-orphans 2>/dev/null || true

echo ""
echo ">>> [2/5] 拉最新代码 (会丢弃服务器上任何本地改动)"
git fetch origin
git reset --hard origin/master
echo "当前 commit: $(git log -1 --oneline)"

echo ""
echo ">>> [3/5] 起依赖栈,等 30 秒让 MySQL/Kafka 就绪"
docker compose -f docker-compose-env.yaml up -d --remove-orphans
sleep 30
docker compose -f docker-compose-env.yaml ps

echo ""
echo ">>> [4/5] 重建镜像并起业务"
docker compose up -d --build
sleep 15

echo ""
echo ">>> [5/5] 状态"
docker compose ps
echo ""
echo "业务最近 30 行日志:"
docker compose logs --tail=30 teamgram

echo ""
echo "============================================================"
echo "部署完成。"
echo "继续跟踪日志:  docker compose logs -f teamgram"
echo "停掉所有服务:  docker compose down && docker compose -f docker-compose-env.yaml down"
echo "============================================================"
