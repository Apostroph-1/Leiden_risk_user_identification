# Leiden - 离线风险用户识别模型

> 业务线：机票（当前版本）+ 酒店 + 门票 + 度假（规划扩展）
> 约束：离线 SQL + 宽表导出 + 多模型打标 + Leiden 社群识别 + 前端可视化

## 项目结构

```
leiden/
├── data/                          # 原始数据（不提交到 git）
│   ├── flight_feature_detail_8.19-90days.csv  # 机票 T-90d 宽表（282MB, 865K 设备）
│   └── model_output/              # 全部模型输出
├── notebooks/                     # Jupyter Notebook（核心代码）
│   ├── 01_cells.txt               # Leiden 社群识别 cell 源码
│   ├── 01_leiden_community.ipynb  # Leiden 社群识别
│   ├── 02_cells.txt               # 多模型分层 cell 源码
│   ├── 02_multi_model_stratify.ipynb  # 多模型投票 + 4 级分层
│   ├── 03_cells.txt               # 合并输出 cell 源码
│   ├── 03_merge_output.ipynb      # 合并原始+社区+模型
│   └── nb_generator.py           # cells.txt -> .ipynb 生成器
├── tools/                         # 前端查询服务
│   ├── community_server.py        # HTTP API + BFS 路径追溯（端口 8766）
│   └── community_viz.html         # D3.js 社群图谱前端
├── docs/                          # 文档
├── sql/                           # 离线 SQL 脚本
├── tableau/                       # Tableau 对接说明
├── requirements.txt               # Python 依赖
└── README.md                      # 本文件
```

## 快速开始

```bash
# 1. 安装依赖
pip install -r requirements.txt

# 2. 执行多模型分层（notebook 或直接运行）
#    在 VSCode 中打开 notebooks/02_multi_model_stratify.ipynb 逐 cell 执行
#    或用命令行：
"D:/Users/yubotai.gao/coding/python/python.exe" -m jupyter nbconvert --to notebook --execute notebooks/02_multi_model_stratify.ipynb --output 02_multi_model_stratify.ipynb --ExecutePreprocessor.timeout=1200

# 3. 执行 Leiden 社群识别
"D:/Users/yubotai.gao/coding/python/python.exe" -m jupyter nbconvert --to notebook --execute notebooks/01_leiden_community.ipynb --output 01_leiden_community.ipynb --ExecutePreprocessor.timeout=600

# 4. 执行合并输出
"D:/Users/yubotai.gao/coding/python/python.exe" -m jupyter nbconvert --to notebook --execute notebooks/03_merge_output.ipynb --output 03_merge_output.ipynb --ExecutePreprocessor.timeout=600

# 5. 启动前端查询服务
"D:/Users/yubotai.gao/coding/python/python.exe" tools/community_server.py
# 浏览器访问 http://127.0.0.1:8766
```

## 模型架构

### 6 模型投票

| 类型 | 模型 | 输出 | 作用 |
|------|------|------|------|
| 无监督 | Isolation Forest | score + label | 全局异常检测 |
| 无监督 | One-Class SVM (RBF) | score + label | 边界检测，可调 nu |
| 无监督 | LOF (novelty) | score + label | 局部密度异常 |
| 监督 | XGBoost | proba + pred | 高精度，SHAP 友好 |
| 监督 | LightGBM | proba + pred | 快速，性能不低于 XGB |
| 监督 | RandomForest | proba + pred | 基线参考 |

> 监督模型基于伪标签训练（强规则标注 + 纯正常样本），无真实标注。

### 7 条规则引擎（v2, 2026-08-26）

| 规则 | 字段 | 阈值 | 命中数 | 命中率 |
|------|------|------|--------|--------|
| is_short_refund_strong | min_refund_pay_interval_sec | <= 600s | - | - |
| is_short_refund_weak | min_refund_pay_interval_sec | 600s < x <= 3600s | - | - |
| is_machine_refund | refund_cnt - cardinality > 0 AND refund_rate > 0.5 | - | - | - |
| is_night_heavy | night_order / total >= 0.5 | - | - | - |
| is_multi_account | distinct_user_id_cnt >= 2 | 23,387 | 2.7% |
| is_multi_pay_tool | distinct_pay_tool_cnt >= 3 | 12,466 | 1.4% |
| is_multi_passenger | uid_distinct_card_num_cnt >= 5 | 121,530 | 14.0% |

`rule_hit_cnt` = 命中规则数之和（0-7）

### 4 级风险分层

vote = 6 模型判为异常的票数（0-6）
rule_hit = 命中规则数（0-7）

| 等级 | 条件 | 设备数 | 占比 |
|------|------|--------|------|
| 高风险 | vote >= 60% AND rule_hit >= 2 | 25,696 | 3.0% |
| 中风险 | vote >= 2 AND rule_hit >= 1 | 201,383 | 23.3% |
| 疑似风险 | vote >= 1 OR rule_hit >= 1 | 522,080 | 60.3% |
| 普通用户 | 其余 | 116,230 | 13.4% |

### 可解释性

- SHAP TreeExplainer：XGBoost 全局/局部重要性
- 决策树 surrogate：对投票率拟合可读规则树（准确率 ~98.5%）
- 模型相关性热力图：6 模型一致性检验

## 前端功能

| 页签 | 功能 |
|------|------|
| 高危分析 | 高危社区行为分类（黄牛/骗赔/薅羊毛等），支持搜索+下钻 |
| 社区指标 | community_id 聚合统计（赔付/退款/异常投票/风险分层），支持搜索+下钻 |
| 社群图谱 | D3.js 力导向图，支持全屏/拖拽/缩放/搜索社区 |
| 路径查询 | 任意两值（device_id / user_id / 支付索引 / 证件 / 手机）BFS 最短路径 |
| 多跳路径 | A 到 B 的所有路径（DFS，最多 20 条） |
| 节点查询 | 任意值查邻居列表 |

### Tableau 10 色系

| 节点类型 | 颜色 | 色值 |
|----------|------|------|
| 设备号 | 蓝 | `#4E79A7` |
| 用户ID | 橙 | `#F28E2B` |
| 支付索引 | 绿 | `#59A14F` |
| 乘机人证件 | 红 | `#E15759` |
| 乘机人手机 | 紫 | `#B07AA1` |

## API 一览

| 路由 | 说明 |
|------|------|
| `GET /` | 前端页面 |
| `GET /api/stats` | 图统计 |
| `GET /api/community_metrics?page=1&size=20` | 社区指标聚合 |
| `GET /api/community_detail/<id>?page=1&size=50` | 社区设备明细 |
| `GET /api/device_detail/<device_id>` | 设备下钻明细 |
| `GET /api/community_analysis?page=1&size=20` | 高危社区行为分析 |
| `GET /api/gang_graph/<id>?limit=200` | 社区图数据 |
| `GET /api/path?a=X&b=Y` | 最短路径（BFS） |
| `GET /api/paths?a=X&b=Y` | 多跳路径（DFS） |
| `GET /api/node/<value>` | 节点查询 |


## Docker 部署（跨电脑同步）

> 详细指南见 [docs/16_docker_deployment.md](docs/16_docker_deployment.md)

### 整体方案

- 代码通过 GitHub 仓库同步（git push / git pull）
- 运行环境通过 Docker 镜像保证一致（Python 3.11 + 所有依赖）
- data/ 文件夹不进 git 也不进镜像，需手动拷贝（约 1.6GB）

### Windows 首次配置（仅一次）

1. 安装 Docker Desktop
2. 安装 WSL2：wsl --install --no-distribution --web-download，然后重启电脑
3. 启动 Docker Desktop，等待左下角变绿
4. docker compose build && docker compose up
5. 访问 http://localhost:8766

### Mac mini 首次配置（仅一次）

1. 安装 Docker Desktop for Mac
2. git clone https://github.com/Apostroph-1/Leiden_risk_user_identification.git
3. 将 data/ 文件夹拷贝到项目根目录（U盘/移动硬盘/局域网传输）
4. docker compose build && docker compose up
5. 访问 http://localhost:8766

> 用途：在另一台电脑上用 Docker 运行同一套环境，确保两边完全一致。

### 前提

1. 目标电脑已安装 [Docker](https://docs.docker.com/get-docker/)
2. 将整个项目文件夹（含 data/）拷贝到目标电脑

### 方式一：docker compose（推荐）

```bash
# 1. 进入项目目录
cd leiden

# 2. 构建并启动服务
docker compose up

# 3. 浏览器访问
# http://localhost:8766
```

### 方式二：docker run（手动）

```bash
# 构建镜像
docker build -t leiden-risk .

# 运行容器（挂载 data 目录）
docker run -d --name leiden -p 8766:8766 -v $(pwd)/data:/app/data leiden-risk

# 浏览器访问
# http://localhost:8766
```

### 在 Docker 中重新训练模型

```bash
# 启动 Jupyter（dev profile）
docker compose --profile dev up jupyter

# 浏览器访问
# http://localhost:8888
# 在 notebooks/ 中打开 .ipynb 逐 cell 执行
```

### 数据文件说明

Docker 镜像不包含 data/ 目录（太大）。通过 volume 挂载：

```
./data/                         -> /app/data/
  flight_feature_detail_*.csv  -> /app/data/flight_feature_detail_*.csv  (原始宽表)
  model_output/                 -> /app/data/model_output/                (模型输出)
./tools/                        -> /app/tools/   (v2.5 起挂载，改代码免 rebuild)
```

> v2.5 起 `docker-compose.yml` 的 server 服务同时挂载了 `./tools`，修改
> `tools/community_server.py` 或 `tools/community_viz.html` 后只需
> `docker compose restart`，无需重新构建镜像。

确保 data/ 目录包含以下文件：

| 文件 | 用途 | 必须有 |
|------|------|--------|
| flight_feature_detail_8.19-90days.csv | 原始宽表 | 训练时需要 |
| model_output/final_merged_output.csv | 合并输出 | 前端展示需要 |
| model_output/device_community.csv | 社区归属 | 前端展示需要 |
| model_output/graph_adjacency.json | 邻接表 | 路径查询需要 |
| model_output/community_analysis.csv | 高危分析 | 高危分析需要 |

### Windows 注意事项

Windows 下 Docker Desktop 需要在设置中开启文件共享，确保项目所在盘符已挂载。

```powershell
# Windows PowerShell
docker compose up
```

## Agent 操作协议

> 接手此项目的 AI agent 必读以下两个文档：
> - [docs/17_agent_handoff_SOP.md](docs/17_agent_handoff_SOP.md) -- 项目全貌、架构、数据流、关键文件
> - [docs/18_agent_operating_protocol.md](docs/18_agent_operating_protocol.md) -- 操作约束、踩坑清单、每次修改的完整流程

## 版本管理与 Git

仓库地址：`https://github.com/Apostroph-1/Leiden_risk_user_identification.git`

### 当前版本

| 标签 | 说明 |
|------|------|
| v2.0 | 7 规则引擎 + 6 模型投票 + Leiden 社群识别 + 前端可视化 |
| v2.1 | 修复 3 条缺失规则列 + 数据清洗 + 文档更新 |
| v2.5 | server 服务挂载 ./tools，改前端/API 代码免 rebuild（restart 即可） |

### 常用命令

```bash
git log --oneline          # 查看提交历史
git add -A                 # 暂存所有更改
git commit -m "v2.1: 修复规则列"
git push origin main       # 推送到远程
```

> 注意：`data/*.csv` 和 `data/*.xlsx` 已在 `.gitignore` 中排除，不会上传原始数据。


