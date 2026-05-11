# byethan fork 部署说明

## 构建镜像

推荐用 GitHub Actions 构建 GHCR 镜像，不占用本地 Mac mini 空间。

1. 打开 `Actions` → `Build and Push Docker Image`
2. 点 `Run workflow`
3. `image_tag` 填一个固定标签，例如 `v2.0.0-byethan.1`
4. `push_latest` 保持 `true`

构建成功后镜像地址：

```text
ghcr.io/byethan/outlook-email-plus:v2.0.0-byethan.1
ghcr.io/byethan/outlook-email-plus:latest
```

也可以用 GitHub CLI：

```bash
gh workflow run docker-build-push.yml -f image_tag=v2.0.0-byethan.1 -f push_latest=true
```

## VPS 一键部署

在 VPS 上用 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/byethan/outlookEmailPlus/main/scripts/deploy-vps.sh | bash
```

指定固定镜像标签：

```bash
curl -fsSL https://raw.githubusercontent.com/byethan/outlookEmailPlus/main/scripts/deploy-vps.sh | IMAGE=ghcr.io/byethan/outlook-email-plus:v2.0.0-byethan.1 bash
```

脚本会自动完成：

- 安装 Docker 与 Compose 插件
- 创建或启用 2G swap
- 创建 `/opt/outlook-email-plus`
- 生成 `.env`
- 写入安全版 `docker-compose.yml`
- 只绑定 `127.0.0.1:5001`
- 启动容器并检查 `/healthz`

部署完成后，在 Mac 上开 SSH 隧道：

```bash
ssh -p 22928 -N -L 5001:127.0.0.1:5001 root@94.16.107.156
```

然后打开：

```text
http://localhost:5001
```

## 更新

固定版本更新：

```bash
cd /opt/outlook-email-plus
sed -i 's#image: .*#image: ghcr.io/byethan/outlook-email-plus:v2.0.0-byethan.1#' docker-compose.yml
docker compose pull
docker compose up -d
curl -fsS http://127.0.0.1:5001/healthz
```

不建议在生产长期使用 Watchtower 或挂载 `/var/run/docker.sock`。这个 fork 的默认部署脚本不会启用它们。
