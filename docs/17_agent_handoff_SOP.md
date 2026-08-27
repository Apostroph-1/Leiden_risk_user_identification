# Agent 交接 SOP

> 本文档供接手此项目的 AI agent 完整理解项目全貌、技术架构和操作流程。

## 1. 项目概述

**项目名称**：Leiden Risk User Identification -- 离线风险用户识别模型

**业务背景**：去哪儿网海外站机票业务，针对 T-90d 按 device_id 聚合的设备行为宽表，使用 6 个机器学习模型 + 7 条规则引擎对设备进行 4 级风险分层，再通过 Leiden 算法识别欺诈团伙社区。

**当前版本**：v2.4（2026-08-27）

**Git 仓库**：https://github.com/Apostroph-1/Leiden_risk_user_identification.git

## 2. 技术架构

### 数据流

`
原始宽表 (CSV, 865K 设备)
    |
    v
02_multi_model_stratify.ipynb  -- 6 模型投票 + 7 规则 + 4 级分层
    |                              输出: device_risk_score.csv (174MB)
    v
01_leiden_community.ipynb      -- Leiden 社区检测
    |                              输出: device_community.csv, graph_adjacency.json
    v
03_merge_output.ipynb          -- 合并原始 + 社区 + 模型
    |                              输出: final_merged_output.csv (402MB)
    v
community_server.py             -- HTTP API + BFS 路径追溯
    |
    v
community_viz.html (D3.js)     -- 前端可视化（6 个页签）
`

### 6 模型投票

| 类型 | 模型 | 参数 | 作用 |
|------|------|------|------|
| 无监督 | Isolation Forest | n_estimators=200, contamination=0.05 | 全局异常检测 |
| 无监督 | One-Class SVM | kernel=rbf, nu=0.05 | 边界检测 |
| 无监督 | LOF | n_neighbors=20, novelty=True | 局部密度异常 |
| 监督 | XGBoost | max_depth=6, eta=0.1, pseudo-label | 高精度，SHAP 友好 |
| 监督 | LightGBM | num_leaves=31, learning_rate=0.1 | 快速，性能好 |
| 监督 | RandomForest | n_estimators=100, max_depth=8 | 基线参考 |

> 监督模型基于伪标签训练（强规则标注 + 纯正常样本），无真实标注。

### 7 条规则引擎（v2）

| 规则 | 字段 | 阈值 |
|------|------|------|
| is_short_refund_strong | min_refund_pay_interval_sec | <= 600s |
| is_short_refund_weak | min_refund_pay_interval_sec | 600s < x <= 3600s |
| is_machine_refund | refund_cnt - cardinality > 0 AND refund_rate > 0.5 | - |
| is_night_heavy | night_order / total >= 0.5 | P95 收紧 |
| is_multi_account | distinct_user_id_cnt >= 2 | - |
| is_multi_pay_tool | distinct_pay_tool_cnt >= 3 | - |
| is_multi_passenger | uid_distinct_card_num_cnt >= 5 | - |

### 4 级风险分层

| 等级 | 条件 | 设备数 | 占比 |
|------|------|--------|------|
| 高风险 | vote >= 60% AND rule_hit >= 2 | 25,696 | 3.0% |
| 中风险 | vote >= 2 AND rule_hit >= 1 | 201,383 | 23.3% |
| 疑似风险 | vote >= 1 OR rule_hit >= 1 | 522,080 | 60.3% |
| 普通用户 | 其余 | 116,230 | 13.4% |

## 3. 关键文件说明

### 代码文件

| 文件 | 作用 | 修改注意 |
|------|------|----------|
| notebooks/01_cells.txt | Leiden 社区检测源码 | 用 nb_generator.py 生成 .ipynb |
| notebooks/01_leiden_community.ipynb | Leiden 社区检测 notebook | 16 cells，可逐 cell 调试 |
| notebooks/02_cells.txt | 多模型分层源码 | 用 nb_generator.py 生成 .ipynb |
| notebooks/02_multi_model_stratify.ipynb | 6 模型 + 7 规则 + 分层 | 33 cells，核心代码 |
| notebooks/03_cells.txt | 合并输出源码 | 用 nb_generator.py 生成 .ipynb |
| notebooks/03_merge_output.ipynb | 合并原始+社区+模型 | 10 cells |
| notebooks/nb_generator.py | cells.txt -> .ipynb 转换器 | 格式: ##MD## / ##CODE## 标记 |
| tools/community_server.py | HTTP API 服务（端口 8766） | Python HTTPServer + BFS |
| tools/community_viz.html | D3.js 前端可视化 | Tableau 10 色系，6 个页签 |

### 配置文件

| 文件 | 作用 |
|------|------|
| Dockerfile | Docker 镜像构建（Python 3.11-slim 基础） |
| docker-compose.yml | 服务编排（server + 可选 jupyter） | v2.5 起 server 挂载 ./tools，改 tools 下代码 restart 即可生效 |
| .dockerignore | Docker 构建排除（data/ 不进镜像） |
| .gitignore | Git 排除（data/*.csv, data/*.xlsx 不提交） |
| requirements.txt | Python 依赖清单 |

### 数据文件（不进 Git，不进 Docker 镜像）

| 文件 | 大小 | 用途 |
|------|------|------|
| data/26.08.27_base.csv | 271MB | 原始宽表（735K 设备，56 列，2026-08-27 重导出修复科学计数法） |
| data/test.xlsx | 699MB | 测试数据 |
| data/model_output/device_risk_score.csv | 174MB | 6 模型 + 7 规则输出 |
| data/model_output/final_merged_output.csv | 402MB | 合并输出（857K 行 x 84 列） |
| data/model_output/graph_adjacency.json | 61MB | 图邻接表 |
| data/model_output/device_community.csv | 14MB | 社区归属（440K 节点） |

## 4. 环境配置

### Docker 方式（推荐，跨平台一致）

`ash
# 1. 克隆代码
git clone https://github.com/Apostroph-1/Leiden_risk_user_identification.git
cd Leiden_risk_user_identification

# 2. 确保 data/ 目录存在且包含数据文件（需手动拷贝）

# 3. 构建并启动
docker compose build
docker compose up -d

# 4. 访问 http://localhost:8766
`

### 本地 Python 方式（开发调试用）

`ash
# Python 3.11+
pip install -r requirements.txt

# 执行 notebook（VSCode 中逐 cell 执行，或命令行）
python -m jupyter nbconvert --to notebook --execute notebooks/02_multi_model_stratify.ipynb
python -m jupyter nbconvert --to notebook --execute notebooks/01_leiden_community.ipynb
python -m jupyter nbconvert --to notebook --execute notebooks/03_merge_output.ipynb

# 启动前端服务
python tools/community_server.py
`

### Docker 镜像加速器（国内必须）

编辑 ~/.docker/daemon.json：
`json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://dockerpull.org",
    "https://dockerhub.icu"
  ]
}
`
修改后重启 Docker Desktop。

## 5. 前端页面说明

URL: http://localhost:8766

| 页签 | 功能 | API |
|------|------|-----|
| 高危分析 | 高危社区行为分类（黄牛/骗赔/薅羊毛等） | /api/community_analysis |
| 社区指标 | community_id 聚合统计（赔付/退款/投票/分层） | /api/community_metrics |
| 社群图谱 | D3.js 力导向图，支持全屏/拖拽/缩放 | /api/gang_graph/<id> |
| 路径查询 | 任意两值 BFS 最短路径 | /api/path?a=X&b=Y |
| 多跳路径 | A 到 B 所有路径（DFS，最多 20 条） | /api/paths?a=X&b=Y |
| 节点查询 | 任意值查邻居列表 | /api/node/<value> |

### Tableau 10 色系

| 节点类型 | 颜色 | 色值 |
|----------|------|------|
| 设备号 | 蓝 | #4E79A7 |
| 用户ID | 橙 | #F28E2B |
| 支付索引 | 绿 | #59A14F |
| 乘机人证件 | 红 | #E15759 |
| 乘机人手机 | 紫 | #B07AA1 |

## 6. 开发流程

### 修改 notebook 代码

1. 编辑 
otebooks/XX_cells.txt（源码）
2. 运行 python notebooks/nb_generator.py 生成 .ipynb
3. 在 VSCode 或 Jupyter 中逐 cell 调试
4. 调试通过后提交

### 修改前端服务

1. 编辑 tools/community_server.py（API 逻辑）
2. 编辑 tools/community_viz.html（前端界面）
3. 重启服务：docker compose restart 或 python tools/community_server.py

> v2.5 起 tools/ 已挂载进容器，改这两个文件后 restart 即可生效，无需 rebuild。

### 修改规则或模型参数

1. 编辑 
otebooks/02_cells.txt 中对应 cell
2. 重新生成 notebook 并执行
3. 输出文件会更新到 data/model_output/

### Git 工作流

`ash
# 每次修改后
git add -A
git commit -m "描述改动"
git push origin main

# 另一台电脑拉取
git pull
`

> 注意：data/ 目录不提交到 Git，通过手动拷贝或 Docker volume 挂载。

## 7. Notebook 结构说明

### 02_multi_model_stratify.ipynb（33 cells）

| Cell | 功能 |
|------|------|
| 1-3 | 导入库 + 设置路径 |
| 4-6 | 读取原始宽表 + 数据清洗（dtype=str 防科学计数法） |
| 7-10 | 特征工程（数值转换 + 派生特征） |
| 11-14 | 7 条规则引擎计算 |
| 15-18 | 伪标签生成（强规则 + 纯正常样本） |
| 19-24 | 6 模型训练（iForest, OCSVM, LOF, XGB, LGBM, RF） |
| 25-27 | 投票 + 4 级分层 |
| 28-30 | SHAP 可解释性 |
| 31-33 | 输出 device_risk_score.csv |

### 01_leiden_community.ipynb（16 cells）

| Cell | 功能 |
|------|------|
| 1-3 | 导入库 + 读取数据 |
| 4-7 | 展开多值字段（user_id, pay_tool, 证件, 手机） |
| 8-10 | 构建图（device_id 为主键，交叉关联） |
| 11-13 | Leiden 社区检测 |
| 14-16 | 输出 device_community.csv + graph_adjacency.json |

### 03_merge_output.ipynb（10 cells）

| Cell | 功能 |
|------|------|
| 1-3 | 读取原始 + 风险评分 + 社区归属 |
| 4-7 | 合并三张表 |
| 8-10 | 输出 final_merged_output.csv |

## 8. 用户偏好（重要）

1. 所有输入输出用 pandas，不用 PowerShell 文本处理
2. 输出用 UTF-8 逗号分隔 CSV
3. 前端色系用 Tableau 10
4. 每次修改后自动 git commit + push + 更新 README + 更新 PRD/SOP
5. 用 require_escalated 绕过 sandbox 限制
6. Notebook 中可调参数处写注释，标明修改范围和影响
7. 不创建冗余 .py 文件，代码放在 .ipynb 或 cells.txt 中
8. 数据读取用 dtype=str 防止 device_id 变科学计数法

## 9. 常见问题

### Docker Desktop 启动报 "virtualisation not detected"
Windows: 关闭 HVCI 内存完整性（Windows 安全中心 -> 设备安全性 -> 内核隔离）

### Docker 构建报 "failed to fetch anonymous token"
国内网络问题，配置镜像加速器（见第 4 节）

### Docker 崩溃报 "sailor-ingest.sock: cannot be accessed"
残留 socket 文件，用 cmd /c del /f /q 删除后重启

### CSV 读取 device_id 变科学计数法
用 pd.read_csv(path, dtype=str) 读取，不自动检测类型

### 前端图谱空白
检查 community_id 是否在 URL 参数中正确传递

## 10. 路径约定

- 项目根目录: 环境变量 LEIDEN_BASE 或当前工作目录
- Docker 内路径: /app（代码），/app/data（数据，volume 挂载）
- Windows 本地: D:\Qunar_work\workbuddy_data\leiden
- Mac: clone 后的项目目录

## 11. API 完整清单

| 路由 | 方法 | 说明 |
|------|------|------|
| / | GET | 前端页面 |
| /api/stats | GET | 图统计 |
| /api/community_metrics?page=1&size=20 | GET | 社区指标聚合 |
| /api/community_detail/<id>?page=1&size=50 | GET | 社区设备明细 |
| /api/device_detail/<device_id> | GET | 设备下钻明细 |
| /api/community_analysis?page=1&size=20 | GET | 高危社区行为分析 |
| /api/gang_graph/<id>?limit=200 | GET | 社区图数据 |
| /api/path?a=X&b=Y | GET | 最短路径 BFS |
| /api/paths?a=X&b=Y | GET | 多跳路径 DFS |
| /api/node/<value> | GET | 节点查询 |
| /api/community_graph/<id> | GET | 指定社区图 |
