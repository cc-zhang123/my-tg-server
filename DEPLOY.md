# teamgram-server 部署运维手册

私有定制版的部署 runbook。仓库：https://github.com/cc-zhang123/my-tg-server

---

## 0. 一句话先搞清楚这个系统长什么样

teamgram-server 是个 **Telegram 协议的私有后端**，客户端连上来收发消息、上传文件、登录注册等等。

它**不是**单个程序，而是 **6 个基础组件 + 11 个业务进程** 拼起来的。

### 基础组件（在服务器上是 6 个独立容器）

| 容器名 | 是什么 | 作用 |
|---|---|---|
| `mysql` | MySQL 8.0 | 存账号、聊天记录这些结构化数据 |
| `redis` | Redis 7 | 缓存、计数器、临时状态 |
| `etcd` | etcd | 11 个业务进程互相发现彼此用的注册中心 |
| `kafka` | Kafka | 消息异步分发（IM 系统的核心管道） |
| `minio` | MinIO | 对象存储，存照片/视频/文件 |
| `minio-mc` | MinIO 客户端 | 启动时自动建好 photos/videos 等桶，做完就退出 |

这 6 个由 [docker-compose-env.yaml](docker-compose-env.yaml) 管理。

### 业务进程（实际只跑在 **1 个**容器里）

容器名是 `teamgram-server-teamgram-1`（就是你 `docker ps` 看到的那个），但容器**里面**同时跑了 11 个独立的业务进程：

```
idgen   status   authsession   dfs   media   biz   msg   sync   bff   session   gnetway
```

每个都干一件具体的事（[runall-docker.sh](teamgramd/bin/runall-docker.sh) 里能看到全部启动顺序）。其中你最常打交道的：

- **`bff`** — 处理登录、注册、发短信验证码（你刚改的阿里云短信就是它在用）
- **`gnetway`** — MTProto 网关，客户端的 TCP/WebSocket 连接直接进它
- **`biz`** — 用户/群组/聊天的核心业务逻辑
- **`msg`** — 消息收发

这 1 个业务容器由 [docker-compose.yaml](docker-compose.yaml) 管理。

### 重点：为什么要"两套 compose"

因为它们是两层：

```
┌──────────────────────────────────────────┐
│  docker-compose.yaml         （业务层）  │  ← 改代码、改 bff.yaml 后重启这层
│   teamgram-server-teamgram-1              │
│   └ 里面跑 11 个进程                       │
└──────────────────────────────────────────┘
              ↓ 依赖
┌──────────────────────────────────────────┐
│  docker-compose-env.yaml     （基础层）  │  ← 这层一般不动
│   mysql / redis / etcd / kafka / minio    │
└──────────────────────────────────────────┘
```

业务层依赖基础层，所以**启动**时要先起基础层、再起业务层；**停止**时反过来。

---

## 1. 三种最常见的操作（直接复制就能用）

> 所有命令都在服务器的 `/opt/teamgram-server` 目录下执行。

### 场景 A：本地改了代码并 push 到 GitHub，要让服务器跟上

```bash
cd /opt/teamgram-server && \
git pull && \
docker compose down && \
docker compose -f docker-compose-env.yaml up -d --remove-orphans && \
sleep 30 && \
docker compose up -d --build && \
sleep 15 && \
docker compose ps && \
docker compose logs --tail=30 teamgram
```

**这一坨在干什么**：
1. `git pull` —— 拉最新代码
2. `docker compose down` —— 停旧的业务容器（基础层不动）
3. 重新确保基础层运行（已经在跑就什么都不做）
4. `docker compose up -d --build` —— **重新编译** Go 代码 + 起新业务容器
5. 看一下状态和最近 30 行日志

**耗时**：纯改 yaml 配置 1~2 分钟（用编译缓存）；改了 Go 代码 5~15 分钟（首次/大改动）。

---

### 场景 B：只是想重启业务（没改代码，比如改了 yaml 配置、卡死了想重启）

```bash
cd /opt/teamgram-server && \
docker compose restart teamgram && \
sleep 10 && \
docker compose logs --tail=50 teamgram
```

**这一坨在干什么**：
- `restart teamgram` —— 把那个跑着 11 个业务进程的容器重启一遍。**基础层（mysql/redis/etcd/kafka/minio）完全不动**。
- 之后看 50 行日志确认正常启动。

**耗时**：10~30 秒。期间客户端会断线重连。

**什么时候用**：
- 改了 `teamgramd/etc2/*.yaml`（比如刚接的阿里云短信配置）
- 容器卡了想重启
- 临时清空业务进程的内存状态

**什么时候不能用**：
- 改了 Go 源码 → 必须走场景 A，因为容器里跑的还是旧二进制

---

### 场景 C：全新机器从零部署

#### C-1 先准备机器（**只做一次**）

```bash
# 装 Docker
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# 开防火墙（只开客户端要连的端口）
firewall-cmd --permanent --add-port=10443/tcp
firewall-cmd --permanent --add-port=11443/tcp
firewall-cmd --permanent --add-port=5222/tcp
firewall-cmd --reload
```

#### C-2 拉代码 + 起服务

```bash
cd /opt && rm -rf teamgram-server && \
git clone https://github.com/cc-zhang123/my-tg-server.git teamgram-server && \
cd teamgram-server && \
cp .env.example .env && \
docker compose -f docker-compose-env.yaml up -d --remove-orphans && \
sleep 30 && \
docker compose up -d --build && \
sleep 15 && \
docker compose ps && \
docker compose logs --tail=50 teamgram
```

**关于 `.env`**：仓库里**只**提交了 [.env.example](.env.example) 模板（`.env` 被 .gitignore 排除，不传 GitHub）。`cp .env.example .env` 这一步必须做，否则 docker compose 找不到变量会落回 compose 里的内置默认值。
- 当前内置默认值已经和 `.env.example` 一致（root=`Root1008613.`、teamgram=`Mysql1008613.`、minio=`Minio1008613.`），所以即使忘了 `cp` 业务也能正常起来；但这些密码**已经写在公开仓库里**，**线上必须改成自己的强口令**，见 § 8.1。

**为什么有 `sleep 30`**：MySQL 容器要 20 多秒才能完全 ready，业务进程起太快会连不上数据库直接 panic 退出。睡 30 秒最稳妥。

#### C-3 验证

```bash
# 应该看到 5 个 Up + 1 个 minio-mc Exited（minio-mc 是建桶用的一次性容器，跑完就退出，正常）
docker compose -f docker-compose-env.yaml ps
docker compose ps

# 应该看到这三个端口在监听
ss -tlnp | grep -E '10443|11443|5222'
```

**首次 build 耗时**：5~15 分钟（编译 11 个 Go 二进制）。

---

## 2. 你目前服务器上跑的就是这个样子

对照你 `docker ps` 输出：

| 容器名 | 属于 |
|---|---|
| `teamgram-server-teamgram-1` | 业务层（11 个进程都在里面） |
| `mysql` | 基础层 |
| `redis` | 基础层 |
| `etcd` | 基础层 |
| `kafka` | 基础层 |
| `minio` | 基础层 |
| (没看到 `minio-mc`) | 一次性建桶容器，跑完就退出了，正常 |

总共 6 个常驻容器 = 你看到的。

---

## 3. 看日志 / 看状态 / 排查问题

### 看日志

```bash
# 业务层 11 个进程混合日志（你最常看的）
docker compose logs -f teamgram

# 只看最近 200 行（不卡终端）
docker compose logs --tail=200 teamgram

# 找特定进程的日志（比如只看 bff 的）
docker compose logs teamgram | grep -i 'bff\|aliyun sms'

# 基础层
docker compose -f docker-compose-env.yaml logs -f mysql
```

### 看状态

```bash
docker compose ps                                 # 业务层
docker compose -f docker-compose-env.yaml ps      # 基础层
docker stats --no-stream                          # 看 CPU/内存占用
```

### 进容器看一下

```bash
docker exec -it teamgram-server-teamgram-1 sh
# 进去后能看到 11 个进程：
ps aux | grep -E 'bff|gnetway|biz|msg'
```

---

## 4. 关于阿里云短信（你刚接的）

改 [teamgramd/etc2/bff.yaml](teamgramd/etc2/bff.yaml) 里的 `Code` 块，填好 4 个 `TODO_FILL_*` 字段，然后**走场景 B 重启业务层**就生效了：

```bash
cd /opt/teamgram-server && docker compose restart teamgram
```

验证：客户端发一次短信，看日志里有没有 `aliyun sms: sent ...`：

```bash
docker compose logs -f teamgram | grep -i 'aliyun sms'
```

成功长这样：`aliyun sms: sent phone=86... bizId=... requestId=...`
失败会有 `aliyun sms: send failed ...`，按错误码查阿里云文档。

---

## 5. 停止 / 清空 / 重装

### 停止（数据保留）

```bash
cd /opt/teamgram-server && \
docker compose down && \
docker compose -f docker-compose-env.yaml down
```

**顺序很重要**：先停业务，再停基础。反过来会有 `network is still in use` 报错（因为两个 compose 共用 `teamgram_net` 网络，业务层在用，基础层就拆不掉）。

数据保留在：
- `./data/mysql/`、`./data/redis/`、`./data/etcd/`、`./data/minio/`
- 命名卷 `teamgram-server_kafka_data`

### 完全清空重装（**会丢全部用户/聊天记录**）

```bash
cd /opt/teamgram-server && \
docker compose down && \
docker compose -f docker-compose-env.yaml down -v && \
sudo rm -rf data/
# 然后回到 § 1 场景 C-2
```

`-v` 是连命名卷一起删（kafka 的数据在命名卷里）。

---

## 6. 常见故障

### `network is still in use`

两个 compose 共用 `teamgram_net`，只停一个会失败。**两个一起停**：

```bash
docker compose down && docker compose -f docker-compose-env.yaml down
```

### 业务容器一直重启 / `Restarting (1)`

```bash
docker compose logs --tail=200 teamgram
```

常见原因：

- **MySQL/etcd 还没好就连了**：基础层先确认 healthy 再起业务层
  ```bash
  docker compose -f docker-compose-env.yaml ps   # 看 STATUS 列是不是都 (healthy) 或 Up
  docker compose up -d
  ```
- **yaml 写错了**：日志里搜 `panic` 或 `error parsing` 那一行
- **磁盘满了**：`df -h`

### MySQL 索引冲突（**只升级才有，全新部署无视**）

跑过官方版的 MySQL 数据卷里有 `idx_chat_requested` 索引，本仓库的迁移 SQL 已去掉它：

```bash
docker compose -f docker-compose-env.yaml exec mysql \
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" teamgram \
  -e "ALTER TABLE chat_invite_participants DROP INDEX idx_chat_requested;"
# ERROR 1091 = 索引本来就不存在，忽略
```

### Docker 卷残留

```bash
docker volume ls | grep teamgram
docker volume rm teamgram-server_kafka_data    # 按需删
```

---

## 7. 客户端怎么连

- **服务器地址**：你这台机器的公网 IP
- **MTProto 端口**：`10443`（TCP）、`11443`（WebSocket）、`5222`（TCP 备用）
- **客户端不能用 Telegram 官方包**，要用 patch 后的 fork（见 [clients/](clients/) 目录），编译时把 DC 地址和 RSA 公钥换成你这台服务器的
- **验证码**：
  - 现在线上配的是阿里云短信 → 用户收到真短信
  - 数据库里 `users.user_type = 5`（test 类型，见 [user_type.go:29](app/service/biz/user/user/user_type.go#L29)）的账号永远收 `12345`（旁路逻辑在 [auth.sendCode_handler.go:334](app/bff/authorization/internal/core/auth.sendCode_handler.go#L334)），方便自己测试不消耗短信费

---

## 8. 关于密码 / 凭证

线上凭证文件清单：

| 文件 | 装的什么 |
|---|---|
| `.env` | MySQL/MinIO 的用户名密码 |
| `teamgramd/etc2/*.yaml` | 各业务进程连基础层用的 DSN、阿里云短信 AK/SK 等 |
| `teamgramd/bin/server_pkcs1.key` | ⚠️ MTProto 通信用的 RSA 私钥，**线上必须自己生成替换** |

`.env` 模板见 `.env.example`，复制改密码即可：

```bash
cp .env.example .env
vi .env
```

改完密码后**同步**改 `teamgramd/etc2/*.yaml` 里所有 DSN 和 MinIO secret，然后走场景 A 重新部署。

### 8.1 修改 MySQL / MinIO 密码（线上必做）

仓库里的默认密码（`Root1008613.` / `Mysql1008613.` / `Minio1008613.`）**已经公开**，谁都能查到。线上**必须**改成自己生成的强口令。

#### 全新部署（数据卷还没建）

最简单——在 `docker compose up` **之前**改：

```bash
cd /opt/teamgram-server
cp .env.example .env
vi .env                # 改 MYSQL_ROOT_PASSWORD / MYSQL_PASSWORD / MINIO_ROOT_PASSWORD
                       # ⚠️ 密码不要带 @ : ? & 等特殊字符（Go DSN 解析会冲突）

# 同步改业务 yaml 里的 DSN 和 MinIO secret
# - teamgramd/etc2/biz.yaml      （DSN 用新 MYSQL_PASSWORD）
# - teamgramd/etc2/msg.yaml      （DSN）
# - teamgramd/etc2/media.yaml    （DSN）
# - teamgramd/etc2/sync.yaml     （DSN）
# - teamgramd/etc2/authsession.yaml （DSN）
# - teamgramd/etc2/dfs.yaml      （SecretAccessKey 用新 MINIO_ROOT_PASSWORD）

# 然后走场景 C-2
```

#### 已经跑起来了，要在不丢数据的前提下改

MySQL/MinIO 的环境变量**只在数据卷首次初始化时生效**。已经有数据后，光改 `.env` 不会改数据库里的实际密码——得在 DB 里 ALTER 一次。

```bash
cd /opt/teamgram-server

# 1) 进 MySQL 改密码（用当前密码登入）
docker compose -f docker-compose-env.yaml exec mysql \
  mysql -uroot -p"当前ROOT密码" -e "
    ALTER USER 'root'@'%'        IDENTIFIED BY '新ROOT密码';
    ALTER USER 'root'@'localhost' IDENTIFIED BY '新ROOT密码';
    ALTER USER 'teamgram'@'%'    IDENTIFIED BY '新TEAMGRAM密码';
    FLUSH PRIVILEGES;
  "

# 2) 改 .env 让健康检查能继续 ping 通
vi .env

# 3) 改业务 yaml 里 5 个 DSN（参考上面列表）
#    MinIO 改密码更麻烦：要么走 mc admin user / mc admin policy，要么直接清空 ./data/minio 重建。
#    安全起见 MinIO 这块建议清数据重来（业务文件可以从客户端重传）。

# 4) 走场景 A（git pull + 重建业务层）
git pull && docker compose down && \
docker compose -f docker-compose-env.yaml up -d --remove-orphans && \
sleep 15 && docker compose up -d --build && \
sleep 15 && docker compose logs --tail=50 teamgram
```

> 验证：日志里看不到 `Access denied for user 'teamgram'` 之类的报错就是接上了。

---

## 9. 速查

```bash
# 部署目录
/opt/teamgram-server/

# 重启业务（不改代码）
docker compose restart teamgram

# 拉代码并重新部署
git pull && docker compose down && \
docker compose -f docker-compose-env.yaml up -d && sleep 30 && \
docker compose up -d --build

# 看日志
docker compose logs -f teamgram

# 看状态
docker compose ps && docker compose -f docker-compose-env.yaml ps

# 全停
docker compose down && docker compose -f docker-compose-env.yaml down

# 进容器
docker exec -it teamgram-server-teamgram-1 sh
```
