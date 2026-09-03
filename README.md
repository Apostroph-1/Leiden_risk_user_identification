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

> v2.6 起 compose 内置 MySQL 8.0 服务（存储建模明细数据，见 docs/16_docker_deployment.md），
> 密码放在根目录 `.env`（已被 .gitignore 排除）。

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
| v2.6 | 新增 MySQL 8.0 服务（明细数据存储，密码走 .env 不进 git）；重写 sql/ 为纯线上取数 SQL（无本地建表） |
| v2.7 | 全部 notebook 改相对路径（去 d:/ 绝对目录）；新基础数据 26.08.27_base.csv 全量重训（735K 设备）；修复 server community_id "6.0" 崩溃 |
| v2.8 | 列名歧义修正：支付索引明细统一为 flight_pay_tool_detail，个数直接用 flight_distinct_pay_tool_cnt（不做派生）；含 pay 边全量重训 |
| v2.9 | 前端规则标签中文化（强短退款/多账号等 7 条）；排序字段修正为 flight_distinct_pay_tool_cnt；02/03 增加数组内部清洗（修复明细空值 25192 行） |
| v3.0 | 新增 sql/02_order_behavior_detail.sql（一行一订单流水，字段合规）；01 保持仅高风险构图（中高危构图实测过慢，用户决策聚焦最高危）；新增 midhigh_device_community.csv 输出 |
| v3.1 | 04/05 notebook：明细序列特征（41 列）+ 融合建模对比；反标签泄露改造（软标签+特征剔除+硬标记富集度评估：黄牛富集 18.6x）；前端新增时序分析页签（SynchroTrap 可视化+设备下钻） |
| v3.2~3.5 | 内部IP页签（黑名单优先展示）；高危分析汇总卡+下钻重排+标签筛选条；方向①②③④全套（套利/档位/自动支付/航线图融合）；退款口径修正+08 质检框架；data_loader 自动发现；项目瘦身 1GB+；指标口径字典 docs/00 |
| v4.0~4.2 | 团伙跃迁模块（P/C 对比下钻）；①指纹团伙（13 跨社区）+②舱位套利（2861 台）；v2 数据重训（退款矛盾 599→38）；深翻页全量可达；上周期全量分层（26.05.29，58919 台带日期前缀）；docs 重构归档+序号重排 |
### 常用命令

```bash
git log --oneline          # 查看提交历史
git add -A                 # 暂存所有更改
git commit -m "v2.1: 修复规则列"
git push origin main       # 推送到远程
```

> 注意：`data/*.csv` 和 `data/*.xlsx` 已在 `.gitignore` 中排除，不会上传原始数据。


