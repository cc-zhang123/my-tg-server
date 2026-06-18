# teamgram-server 部署运维手册

私有定制版的部署 runbook。仓库:https://github.com/cc-zhang123/my-tg-server

裁剪后只跑 6 个依赖 + 11 个业务服务,删除了 ES/Kibana/Filebeat/go-stash/Jaeger/Prometheus/Grafana/node-exporter 这些可观测组件(业务零依赖)。

---

## 一、服务器要求

- CentOS 7/9,4C8G+,公网 IP
- 已装 Docker Engine + docker compose plugin
- 已开防火墙端口:`10443` / `11443` / `5222`(MTProto 客户端用)
- 其他端口(3306/6379/2379/9000/9001/9092)**不要**对公网开放

---

## 二、一次性准备(新服务器只做一次)

### 装 Docker

```bash
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker version
```

### 开防火墙

```bash
firewall-cmd --permanent --add-port=10443/tcp
firewall-cmd --permanent --add-port=11443/tcp
firewall-cmd --permanent --add-port=5222/tcp
firewall-cmd --reload
firewall-cmd --list-ports
```

---

## 三、首次部署(全新)

```bash
cd /opt
rm -rf teamgram-server                                                    # 如果之前有空目录
git clone https://github.com/cc-zhang123/my-tg-server.git teamgram-server
cd teamgram-server

# 1. 起依赖栈(kafka / etcd / redis / mysql / minio / minio-mc)
docker compose -f docker-compose-env.yaml up -d --remove-orphans
sleep 30
docker compose -f docker-compose-env.yaml ps                              # 期望除 minio-mc(Exited 0) 外都 Up

# 2. 起业务
docker compose up -d
sleep 15

# 3. 验证
docker compose ps                                                         # teamgram 容器 Up
docker compose logs --tail=80 teamgram                                    # 看到 "run idgen ..." → "run gnetway ..."
ss -tlnp | grep -E '10443|11443|5222'                                     # 端口监听上
```

---

## 四、日常更新(本地推新代码后)

```bash
cd /opt/teamgram-server
git pull
docker compose -f docker-compose-env.yaml up -d --remove-orphans          # 配置改了才有效
docker compose up -d --build                                              # Go 代码改了要加 --build
docker compose logs -f teamgram
```

---

## 五、常用操作

### 看状态

```bash
docker compose ps
docker compose -f docker-compose-env.yaml ps
```

### 看日志

```bash
docker compose logs -f teamgram                                           # 11 个业务服务的混合日志
docker compose -f docker-compose-env.yaml logs -f mysql
docker compose -f docker-compose-env.yaml logs --tail=200 kafka
```

### 重启单个服务

```bash
docker compose restart teamgram
docker compose -f docker-compose-env.yaml restart mysql
```

### 停止(数据保留)

```bash
docker compose down                                                       # 先停业务
docker compose -f docker-compose-env.yaml down                            # 再停依赖
# 数据保留在 ./data/(mysql/redis/etcd/minio) 和命名卷 kafka_data
```

### 完全清空重来(**会丢所有用户/聊天数据**)

```bash
docker compose down
docker compose -f docker-compose-env.yaml down -v                         # -v 删命名卷
sudo rm -rf data/
# 然后回到 § 三 首次部署
```

---

## 六、故障排查

### `network is still in use`

两个 compose 共用 `teamgram_net`,只 down 一个会失败。**两个都 down**:

```bash
docker compose down
docker compose -f docker-compose-env.yaml down
```

### MySQL 索引冲突(只升级才有,全新部署忽略)

跑过官方版的 MySQL 数据卷里有 `idx_chat_requested` 索引,本仓库的迁移 SQL 已去掉它:

```bash
docker compose -f docker-compose-env.yaml exec mysql \
  mysql -uroot -proot teamgram \
  -e "ALTER TABLE chat_invite_participants DROP INDEX idx_chat_requested;"
# ERROR 1091 = 索引本来就不存在,忽略
```

### 业务容器一直重启

```bash
docker compose logs teamgram | tail -200
```

常见原因:
- MySQL/etcd 还没 ready 业务就连上去了 → 先 `docker compose -f docker-compose-env.yaml ps` 看依赖都 healthy 再 `docker compose up -d`
- yaml 配置错误 → 看日志里 `panic` 行定位哪个服务

### 找不到 yaml 文件 / 不是 git 目录

```bash
ls -la /opt/teamgram-server
# 如果是空目录,见 § 三 首次部署的 rm + clone
```

### Docker volume 残留(干净重装前清理)

```bash
docker volume ls | grep teamgram-server
docker volume rm teamgram-server_kafka_data                               # 按需
```

---

## 七、客户端连接

- **服务器地址**:你的公网 IP
- **MTProto 端口**:`10443`(TCP)、`11443`(WebSocket)、`5222`(TCP 备用)
- **默认验证码**:`12345`(生产必须改,见 [README-zh.md](README-zh.md))
- **客户端**:不能用 Telegram 官方包,要用 patch 后的 fork(见 [clients/](clients/) 目录),编译时把 DC 地址和 RSA 公钥换成你这台服务器的

---

## 八、改密码(可选,线上必做)

默认密码(`.env.example` 里):

| 组件 | User | Password |
|---|---|---|
| MySQL root | root | root |
| MySQL 业务 | teamgram | teamgram |
| MinIO | minio | miniostorage |

短期内端口都没对公网开,默认密码先用没事。等业务稳了再改,步骤:

1. 改 `.env`(从 `.env.example` 复制)
2. 改 `teamgramd/etc/*.yaml` 里所有 DSN 和 MinIO secret
3. 如果数据库已初始化:`docker compose exec mysql mysql -uroot -proot -e "ALTER USER ...;"` 手工改;否则 `down -v` + `rm -rf data/` 重新初始化
4. 重启:`docker compose -f docker-compose-env.yaml up -d && docker compose restart teamgram`

---

## 九、目录结构速查

```
/opt/teamgram-server/
├── docker-compose.yaml              # 业务 11 服务容器
├── docker-compose-env.yaml          # 依赖栈(kafka/etcd/redis/mysql/minio)
├── .env.example                     # 环境变量模板,复制成 .env 改密码用
├── teamgramd/
│   ├── etc/                         # 11 个 *.yaml 业务配置(MySQL DSN/Redis/MinIO 等)
│   ├── bin/server_pkcs1.key         # ⚠️ RSA 私钥(线上必须自己重新生成替换)
│   └── deploy/sql/                  # MySQL 初始化 SQL
└── data/                            # 持久化数据(mysql/redis/etcd/minio)
```
