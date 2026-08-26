# Leiden - 风险用户识别模型

> 业务线：机票（首版） + 酒店 + 门票 + 工单日志（扩展）
> 约束：线上仅跑 SQL 落离线表，线下用离线表 + python + mysql 建模，Tableau 接 mysql 可视化

## 交付物清单

### 文档
- `docs/01_field_dictionary.md` — 字段字典与 19 处口径修正
- `docs/02_field_design.md` — 多业务线风险模型字段体系
- `docs/03_PRD.md` — 产品需求文档
- `docs/04_execution_plan.md` — 执行计划（P0-P5）
- `docs/05_extended_metrics.md` — 扩展指标清单（A-R 共 18 类）
- `docs/06_device_metrics.md` — 设备号维度指标体系
- `docs/07_unsupervised_risk_model.md` — 无监督风险模型方案
- `docs/08_multi_model_stratification.md` — 多模型对比 + 4 级分层
- `docs/09_execution_results.md` — 全量执行结果报告
- `docs/14_module_workflow_guide.md` — 模块改动手册（含 API/DB 替代离线表方案）
- `docs/15_community_behavior_analysis.md` — 高危社区行为特征归纳分析

### SQL
- `sql/01_offline_tables.sql` — 离线 DWD/DWS 建表与跑批（ClickHouse/Spark）
- `sql/02_mysql_schema.sql` — 本地 mysql 库表结构
- `sql/03_export_to_mysql.sql` — 离线导 mysql 模板
- `sql/04_online_sql_v2.sql` — 线上 SQL v2（5 DWD + 6 DWS）
- `sql/05_device_sql.sql` — 设备号维度线上 SQL（StarRocks，9 张表）

### Python
- `python/01_feature_engineering.py` — 特征工程（CH 取数 → mysql）
- `python/02_label_engineering.py` — 标签回溯标注
- `python/03_model_train.py` — LightGBM 训练
- `python/04_model_inference.py` — 推理 + 写 mysql
- `python/05_export_to_mysql.py` — DWS 表导 mysql
- `python/06_unsupervised_risk_model.py` — 无监督风险模型（iForest + K-Means + SHAP）
- `python/07_leiden_community.py` — Leiden 团伙识别
- `python/08_multi_model_stratify.py` — 多模型对比 + 4 级风险分层
- `python/requirements.txt` — 依赖

### Notebooks
- `notebooks/08_multi_model_stratify.ipynb` — 多模型风险分类（6 模型 + 4 级分层 + SHAP 可解释）
- `notebooks/07_leiden_community.ipynb` — Leiden 团伙识别（explode 多值列 + 社区发现 + BFS 路径追踪）
- `notebooks/09_merge_output.ipynb` — 合并最终输出表（原始宽表 + community_id + 全模型打标 + risk_level）
- `notebooks/nb_generator.py` — 通用 notebook 生成器

### 查询工具与可视化
- `tools/community_server.py` — 团伙社区查询服务（HTTP API + BFS 路径追踪，端口 8766）
- `tools/community_viz.html` — D3.js 力导向图前端（Tableau 10 色系，7 个功能页签）

### Tableau
- `tableau/README.md` — 看板配置说明

## 快速开始

```bash
# 1. 装 python 依赖
pip install -r python/requirements.txt

# 2a. 多模型风险分类（推荐用 notebook）
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/08_multi_model_stratify.py

# 2b. Leiden 团伙识别
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/07_leiden_community.py --risk-only --min-community-size 3

# 2c. 启动团伙查询可视化服务
python tools/community_server.py
# 浏览器自动打开 http://127.0.0.1:8766

# 产出目录：data/model_output/
# - device_risk_score.csv     设备风险分层主表（4 级）
# - gang_list.csv             团伙列表
# - exploded_edges.csv        展开后的边表
# - device_community.csv      节点级社区归属
# - graph_adjacency.json      邻接表
# - final_merged_output.csv   合并最终输出
# - shap_summary.png          SHAP 特征重要性
# - tree_rules.png / .txt     决策树 surrogate 可解释规则
# - xgb.pkl / lgb.pkl / rf.pkl 训练好的模型
```

## 前端功能（7 个页签）

| 页签 | 功能 |
|------|------|
| 高危分析 | 社区行为归类（黑灰产/黄牛/骗赔/薃羊毛），点击社区→设备明细（按支付索引降序）→点击设备下钻 userId/手机/支付索引/证件明细，三级联动全部可溯源 |
| 社区指标 | 按 community_id 聚合统计指标（赔付金额、退款率、异常投票、风险分布等），支持排序分页+社区ID搜索，点击社区展开设备明细，点击设备行下钻展示 userId/手机/支付索引/证件 明细 |
| 社区图谱 | D3.js 力导向图，支持鼠标滚轮缩放/拖拽平移/可调画布，按度排序取 Top N 节点，双击节点可填入路径查询 |
| 路径查询 | 输入任意两个值（device_id / user_id / 支付索引 / 证件 / 手机），返回 A→B 最短路径，每步标注节点类型和连接关系 |
| 多条路径 | 返回 A→B 之间多条路径（DFS），最多可配 20 条 |
| 节点查询 | 输入任意值，返回所属社区、度数、邻居列表 |

### 节点命名与自动解析

- 设备号: 原始 device_id
- 其他节点带前缀: `user::值` / `pay::值` / `card::值` / `mobile::值`
- 查询时无需手动加前缀，服务端自动匹配

### Tableau 10 色系

| 节点类型 | 颜色 | 色值 |
|----------|------|------|
| 设备号 | 蓝 | `#4E79A7` |
| 用户ID | 橙 | `#F28E2B` |
| 支付索引 | 绿 | `#59A14F` |
| 乘机人证件 | 红 | `#E15759` |
| 乘机人手机 | 紫 | `#B07AA1` |

### API 一览

| 端点 | 说明 |
|------|------|
| `GET /` | 前端页面 |
| `GET /api/stats` | 图统计（节点数/社区数/团伙数/最大团伙） |
| `GET /api/gangs?page=1&size=20` | 团伙列表（分页，支持 `high_risk=1`） |
| `GET /api/gang/<id>` | 团伙详情 |
| `GET /api/gang_graph/<id>?limit=200` | 团伙图数据（节点+边） |
| `GET /api/path?a=X&b=Y` | 最短路径（BFS） |
| `GET /api/paths?a=X&b=Y` | 多条路径（DFS） |
| `GET /api/node/<value>` | 查找节点所属社区与邻居 |
| `GET /api/community_metrics?page=1&size=20&sort=comp_total&dir=desc` | 社区指标聚合（按赔付/退款/订单量等排序） |
| `GET /api/community_detail/<id>?page=1&size=50&sort=pay_tool` | 指定社区的设备明细（分页，默认按支付索引降序） |
| `GET /api/device_detail/<device_id>` | 设备下钻明细（userId/手机/支付索引/证件列表） |
| `GET /api/community_analysis?page=1&size=20` | 高危社区行为分类分析（自动归类黑灰产/黄牛/骗赔/薃羊毛） |

## 执行结果摘要

### 风险分类（865K 设备）

| 风险级别 | 设备数 | 占比 | 条件 |
|----------|--------|------|------|
| 高风险 | 27,232 | 3.1% | vote >= 60% AND rule_hit >= 2 |
| 中风险 | 218,967 | 25.3% | vote >= 2 AND rule_hit >= 1 |
| 疑似风险 | 512,056 | 59.2% | vote >= 1 OR rule_hit >= 1 |
| 普通用户 | 107,134 | 12.4% | 其余 |

### Leiden 团伙识别（仅高风险设备构图）

| 指标 | 值 |
|------|------|
| 构图设备 | 27,199 |
| 总节点 | 440,778 |
| 总边 | 424,875 |
| 社区数 | 23,561 |
| 最大团伙 | 4,936 节点 |

> 详细结果见 `docs/09_execution_results.md`

## 版本管理（Git）

项目已纳入 Git 版本控制，仓库地址：
`https://github.com/Apostroph-1/Leiden_risk_user_identification.git`

### 当前版本

| 标签 | 说明 |
|------|------|
| v1.0 | 离线风险用户识别 + Leiden 团伙识别 + 多模型分层 + 前端可视化 |
| v1.1 | 社区指标模块 + git 版本管理 |
| v1.2 | 修复社区图谱TDZ bug + 分页跳转 + 度数说明 |
| v1.3 | 删除团伙列表 + 社区指标增强(社区ID搜索+设备下钻+支付索引排序) + 高危社区行为分析 + 模块改动手册 |
| v1.4 | 新增「高危分析」前端模块（行为归类+社区明细+设备下钻三级联动） |

### 常用命令

```bash
git log --oneline          # 查看提交历史
git tag                    # 查看所有版本标签
git checkout v1.0          # 回退到 v1.0
git reset --hard v1.0      # 彻底回退到 v1.0
```

### 发布新版本

```bash
git add -A
git commit -m "v1.4: 新功能描述"
git tag v1.4
git push origin main --tags
```
