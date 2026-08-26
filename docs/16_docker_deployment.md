# Docker 部署指南

## 概述

本项目通过 Docker 容器化，实现 Windows 和 Mac mini 两台电脑的环境同步。
代码通过 GitHub 仓库同步，数据文件（data/ 文件夹）需手动传输。

## 架构

`
GitHub 仓库 (代码)  ──>  git clone  ──>  本地工作目录
                                          │
data/ 文件夹 (手动拷贝)  ──────────────> │
                                          │
Docker 容器  <──  docker compose up  <────┘
     │
     └──> http://localhost:8766  (社区查询前端)
     └──> http://localhost:8888  (Jupyter notebook, 可选)
`

## 前置条件

### Windows 机器
1. 安装 Docker Desktop（已安装）
2. 安装 WSL2（已安装，需重启电脑生效）
3. Git 已配置

### Mac mini
1. 安装 Docker Desktop for Mac
2. 安装 Git (rew install git 或 Xcode Command Line Tools)

## 步骤一：Windows 机器（当前电脑）

### 1.1 重启电脑
WSL2 安装后需要重启系统才能生效。

### 1.2 启动 Docker Desktop
重启后打开 Docker Desktop 应用，等待左下角状态变为绿色"Running"。

### 1.3 构建并启动容器
在项目根目录下执行：

`powershell
cd D:\Qunar_work\workbuddy_data\leiden
docker compose build
docker compose up
`

构建首次需要下载 Python 基础镜像和安装依赖，约 5-10 分钟。
后续启动只需几秒。

### 1.4 验证
打开浏览器访问 http://localhost:8766 ，应看到社区查询前端页面。

### 1.5 停止容器
Ctrl+C 停止，或 docker compose down 清理。

## 步骤二：Mac mini

### 2.1 克隆代码仓库
`ash
git clone https://github.com/Apostroph-1/Leiden_risk_user_identification.git
cd Leiden_risk_user_identification
`

### 2.2 传输数据文件
将 Windows 电脑上 data/ 文件夹整体拷贝到 Mac mini 的项目目录下。

传输方式（任选其一）：
- U 盘 / 移动硬盘拷贝（推荐，数据约 1.6GB）
- 同一局域网 SCP：scp -r user@windows_ip:/D/Qunar_work/workbuddy_data/leiden/data ./
- 百度网盘 / AirDrop 等

所需文件清单：
`
data/
├── flight_feature_detail_8.19-90days.csv      (269MB, 原始输入)
├── test.xlsx                                    (699MB, 测试数据)
└── model_output/
    ├── device_risk_score.csv                   (174MB, 风险评分)
    ├── final_merged_output.csv                 (402MB, 合并输出)
    ├── graph_adjacency.json                    (61MB, 图邻接)
    └── device_community.csv                    (14MB, 社区归属)
`

### 2.3 构建并启动
`ash
docker compose build
docker compose up
`

### 2.4 验证
打开浏览器访问 http://localhost:8766

## 常用命令

| 操作 | 命令 |
|------|------|
| 启动前端服务 | docker compose up |
| 后台启动 | docker compose up -d |
| 停止 | docker compose down |
| 重新构建（代码更新后） | docker compose build |
| 启动 Jupyter（可选） | docker compose --profile dev up jupyter |
| 查看日志 | docker compose logs -f |

## 日常开发流程

### Windows 上修改代码后
1. 修改 notebook 或 server 代码
2. git add . && git commit -m "描述" && git push
3. docker compose build && docker compose up

### Mac mini 上拉取更新
1. git pull
2. docker compose build && docker compose up

## 注意事项

- data/ 文件夹不会通过 git 或 Docker 镜像传输，需手动同步
- 如果只修改了 	ools/community_server.py 或 	ools/community_viz.html，需要 docker compose build 重新构建
- Docker 端口映射：8766（前端服务）、8888（Jupyter）
- 容器内代码路径为 /app，数据路径为 /app/data
