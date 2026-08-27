# Docker 部署指南

## 概述

本项目通过 Docker 容器化，实现 Windows 和 Mac mini 两台电脑的环境同步。
代码通过 GitHub 仓库同步，数据文件（data/ 文件夹）需手动传输。

## 前置条件

### Windows 机器
1. 安装 Docker Desktop 4.88+
2. 安装 WSL2：wsl --install --no-distribution --web-download，重启电脑
3. 关闭内存完整性（HVCI）：Windows 安全中心 -> 设备安全性 -> 内核隔离 -> 关闭内存完整性 -> 重启
4. 配置 Docker 镜像加速器（见下方）

### Mac mini
1. 安装 Docker Desktop for Mac
2. Git 已安装

## Docker 镜像加速器配置

国内网络无法直连 Docker Hub，需要配置镜像加速器。

编辑 ~/.docker/daemon.json（Windows 路径：D:\Users\<用户名>\.docker\daemon.json）：

`json
{
  "builder": { "gc": { "defaultKeepStorage": "20GB", "enabled": true } },
  "experimental": false,
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://dockerpull.org",
    "https://dockerhub.icu",
    "https://docker.nastech.cc"
  ]
}
`

修改后重启 Docker Desktop。

## Windows 步骤

### 1. 启动 Docker Desktop
打开 Docker Desktop 应用，等待左下角状态变绿 Running。

### 2. 构建并启动
`powershell
cd D:\Qunar_work\workbuddy_data\leiden
docker compose build
docker compose up -d
`

构建首次约 15-20 分钟（含下载 Python 基础镜像 + 安装所有依赖）。
后续启动只需几秒（数据加载约 15 秒）。

### 3. 验证
打开 http://localhost:8766

### 4. 停止
`powershell
docker compose down
`

## Mac mini 步骤

### 1. 克隆代码
`ash
git clone https://github.com/Apostroph-1/Leiden_risk_user_identification.git
cd Leiden_risk_user_identification
`

### 2. 配置镜像加速器
同上方步骤，编辑 ~/.docker/daemon.json（Mac 路径：~/.docker/daemon.json）。

### 3. 传输数据文件
将 Windows 上 data/ 文件夹整体拷贝到项目目录。

传输方式（任选）：
- U 盘 / 移动硬盘（推荐，约 1.6GB）
- 局域网 SCP
- AirDrop 等

所需文件：
- data/flight_feature_detail_8.19-90days.csv（269MB）
- data/model_output/（约 700MB，含 final_merged_output.csv 等）

### 4. 构建并启动
`ash
docker compose build
docker compose up -d
`

### 5. 验证
打开 http://localhost:8766

## 常用命令

| 操作 | 命令 |
|------|------|
| 后台启动 | docker compose up -d |
| 前台启动（看日志） | docker compose up |
| 停止 | docker compose down |
| 重新构建 | docker compose build |
| 查看日志 | docker logs leiden-server-1 |
| 启动 Jupyter（可选） | docker compose --profile dev up jupyter |

## 日常同步

> v2.5 起 server 服务挂载了 ./tools 目录（见 docker-compose.yml），改 tools/ 下的代码
> （community_server.py、community_viz.html）后**无需重新 build**，只需
> `docker compose restart` 即可生效。改 notebooks/ 或依赖仍需 rebuild。

### Windows 改代码后
```powershell
git add -A; git commit -m "描述"; git push
# 只改了 tools/ 下的文件：
docker compose restart
# 改了 notebooks/、Dockerfile、requirements.txt：
docker compose build; docker compose up -d
```

### Mac 拉取更新
```bash
git pull
# 只改了 tools/ 下的文件：
docker compose restart
# 改了 notebooks/、Dockerfile、requirements.txt：
docker compose build; docker compose up -d
```

## 常见问题

### Docker Desktop 启动报 "virtualisation support wasn't detected"
原因：Windows HVCI（内存完整性）占用了 VT-x。
解决：Windows 安全中心 -> 设备安全性 -> 内核隔离 -> 关闭内存完整性 -> 重启。

### Docker 构建报 "failed to fetch anonymous token"
原因：国内无法直连 Docker Hub。
解决：配置镜像加速器（见上方），重启 Docker Desktop。

### Docker Desktop 崩溃报 "sailor-ingest.sock: The file cannot be accessed"
原因：Docker 异常退出后残留 Unix socket 文件。
解决：
1. 停止 Docker：Get-Process | Where-Object { .ProcessName -match "docker" } | Stop-Process -Force
2. 关闭 WSL：wsl --shutdown
3. 删除残留文件：cmd /c del /f /q "D:\Users\<用户名>\AppData\Local\Docker\run\*" 和 cmd /c del /f /q "D:\Users\<用户名>\AppData\Local\docker-secrets-engine\*"
4. 重启 Docker Desktop
