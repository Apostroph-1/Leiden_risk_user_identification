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
 
 ### Python（.py 命令行版）
- `python/01_feature_engineering.py` — 特征工程（CH 取数 → mysql）
- `python/02_label_engineering.py` — 标签回溯标注
- `python/03_model_train.py` — LightGBM 训练
- `python/04_model_inference.py` — 推理 + 写 mysql
- `python/05_export_to_mysql.py` — DWS 表导 mysql
- `python/06_unsupervised_risk_model.py` — 无监督风险模型（iForest + K-Means + SHAP）
- `python/07_leiden_community.py` — Leiden 团伙识别
- `python/08_multi_model_stratify.py` — 多模型对比 + 4 级风险分层
- `python/requirements.txt` — 依赖
  
 ### Notebooks（可调版，推荐在 VSCode 中打开微调）
- `notebooks/08_multi_model_stratify.ipynb` — 多模型风险分类（6 模型 + 4 级分层 + SHAP 可解释，33 cells，25+ [TUNABLE] 参数）
- `notebooks/07_leiden_community.ipynb` — Leiden 团伙识别（explode 多值列 + 社区发现 + BFS 路径追踪，16 cells，8 [TUNABLE] 参数）
- `notebooks/09_merge_output.ipynb` -- 合并最终输出表（原始宽表 + community_id + 全模型打标 + risk_level，10 cells）
- `notebooks/nb_generator.py` — 通用 notebook 生成器（从 `*_cells.txt` 重建 .ipynb）
- `notebooks/07_cells.txt` / `notebooks/08_cells.txt` / `notebooks/09_cells.txt` — notebook 源码文本（可用编辑器直接修改后重新生成）
 
 ### 查询工具与可视化
- `tools/community_server.py` — 团伙社区查询服务（HTTP API + BFS 路径追踪，端口 8766）
- `tools/community_viz.html` — D3.js 力导向图前端（Tableau 10 色系，6 个功能页签）
 
 ### Tableau
- `tableau/README.md` — 看板配置说明

## 快速开始

```bash
# 1. 装 python 依赖
pip install -r python/requirements.txt

# ---- 设备号维度风险分类 + 团伙识别 ----
# 数据：data/flight_feature_detail_8.19-90days.csv（865K 设备，T-90d 聚合）

# 2a. 多模型风险分类（推荐用 notebook，可在 VSCode 中微调）
#    在 VSCode 中打开 notebooks/08_multi_model_stratify.ipynb，逐 cell 运行
#    或命令行运行 .py 版本（不含 tqdm 进度条）：
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/08_multi_model_stratify.py
#    调试样本（采样 10000 行快速跑通）：
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/08_multi_model_stratify.py --sample 10000

# 2b. Leiden 团伙识别（推荐用 notebook）
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/07_leiden_community.py --risk-only --min-community-size 3

# 2c. 启动团伙查询可视化服务
python tools/community_server.py
#    浏览器自动打开 http://127.0.0.1:8766
#    支持路径追踪、多条路径、节点查询、社区图谱（D3 力导向 + Tableau 色系）

# 产出目录：data/model_output/
# - device_risk_score.csv     865K 设备风险分层主表（4 级）
# - gang_list.csv             团伙列表（24K 个团伙）
# - exploded_edges.csv        展开后的边表（device ↔ entity，完整溯源）
# - device_community.csv      节点级社区归属（440K 节点）
# - graph_adjacency.json      邻接表（供查询服务加载）
# - final_merged_output.csv    合并最终输出（原始宽表 + community_id + 全模型打标 + risk_level）
# - graph_edges.csv           图边表（可导入 Gephi）
# - shap_summary.png          SHAP 特征重要性
# - tree_rules.png / .txt     决策树 surrogate 可解释规则
# - xgb.pkl / lgb.pkl / rf.pkl 训练好的模型
# - risk_level_distribution.png  4 级分布柱状图
# - model_correlation.png / .csv 6 模型相关性热力图

# ---- 传统监督建模流程（需 mysql + 线上离线表）----
# 2. 建 mysql 库表
mysql -u root -p < sql/02_mysql_schema.sql

# 3. 线上跑 DWD/DWS（需调度系统）
#    见 sql/01_offline_tables.sql

# 4. 离线表导 mysql
python python/05_export_to_mysql.py --start 2026-03-01 --end 2026-08-17

# 5. 跑特征工程
python python/01_feature_engineering.py --date 2026-08-17

# 6. 跑标签
python python/02_label_engineering.py --date 2026-08-17

# 7. 训练
python python/03_model_train.py --end-date 2026-08-17

# 8. 推理
python python/04_model_inference.py --date 2026-08-17

# 9. Tableau 接 mysql 建看板
#    见 tableau/README.md
```
 
## Notebook 使用说明

两个 notebook 都标记了 `[TUNABLE]` 注释，标明可微调的参数及其影响。在 VSCode 中打开 `.ipynb` 文件后，搜索 `[TUNABLE]` 即可定位所有可调参数。

### `08_multi_model_stratify.ipynb` — 风险分类

| 位置 | 参数 | 默认值 | 调整影响 |
|------|------|--------|----------|
| Cell 1 | `INPUT_CSV` | 宽表路径 | 换数据时改这里 |
| Cell 1 | `SAMPLE_N` | `None`（全量） | 设正整数做采样调试 |
| Cell 7 | `FEATURE_COLS` | 30+ 特征 | 增删特征影响模型输入维度 |
| Cell 9 | 伪标签规则阈值 | refund_rate>0.5 等 | 改变正/负样本分布 |
| Cell 11 | `n_estimators` / `contamination` | 200 / 0.1 | iForest 异常比例 |
| Cell 13 | `sample_n` / `nu` | 20000 / 0.1 | OC-SVM 采样数与异常上界 |
| Cell 15 | `n_neighbors` | 50 | LOF 局部邻域（默认20偏小，30K采样下50更稳定） |
| Cell 17-23 | XGB/LGB/RF 超参 | 见注释 | 影响监督模型性能 |
| Cell 27 | 分层阈值 | 0.6/2, 2/1, 1/1 | **最重要调参点**，直接决定各级别设备数量 |
| Cell 29 | `sample_n` | 3000 | SHAP 采样数 |
| Cell 30 | `max_depth` | 4 | 决策树 surrogate 规则粒度 |

### `07_leiden_community.ipynb` — 团伙识别

| 位置 | 参数 | 默认值 | 调整影响 |
|------|------|--------|----------|
| Cell 1 | `INPUT_CSV` / `RISK_CSV` | 宽表/风险评分路径 | 换数据时改这里 |
| Cell 1 | `RISK_ONLY` | `True` | True=仅高风险设备构图，False=全量 |
| Cell 1 | `MIN_COMMUNITY_SIZE` | 3 | 小于该值的社区被筛除 |
| Cell 7 | 列映射 | user/pay/card/mobile | 增删列调整构图范围 |
| Cell 5 | `is_high_risk_gang` 条件 | RISK_ONLY=True: community_size>=10; False: rate>=0.5 | 高危团伙标记阈值 |

### 重建 notebook

若 `*_cells.txt` 被修改后需重新生成 `.ipynb`：

```bash
python notebooks/nb_generator.py notebooks/07_cells.txt notebooks/07_leiden_community.ipynb
python notebooks/nb_generator.py notebooks/08_cells.txt notebooks/08_multi_model_stratify.ipynb
python notebooks/nb_generator.py notebooks/09_cells.txt notebooks/09_merge_output.ipynb
```

## 团伙查询可视化服务

```bash
python tools/community_server.py
# 默认端口 8766，可 --port 8888 指定
# 自动打开浏览器 http://127.0.0.1:8766
# 首次启动需加载邻接表（约 10-20s），tqdm 显示进度
```

### 前端功能（6 个页签）

| 页签 | 功能 |
|------|------|
| 社区指标 | 按 community_id 聚合统计指标（赔付金额、退款率、异常投票、风险分布等），支持排序分页+社区ID搜索，点击社区展开设备明细（默认按支付索引个数降序），点击设备行下钻展示 userId/手机/支付索引/证件 明细 |
| 社区图谱 | D3.js 力导向图，支持鼠标滚轮缩放/拖拽平移/可调画布，按度排序取 Top N 节点，双击节点可填入路径查询 |
| 路径查询 | 输入任意两个值（device_id / user_id / 支付索引 / 证件 / 手机），返回 A→B 最短路径，每步标注节点类型和连接关系 |
| 多条路径 | 返回 A→B 之间多条路径（DFS），最多可配 20 条 |
| 节点查询 | 输入任意值，返回所属社区、度数、邻居列表 |
| 社区指标 | 按 community_id 聚合统计指标（赔付金额、退款率、异常投票、风险分布等），支持排序分页，双击社区展开设备明细，设备行双击跳转节点查询 |

### 节点命名与自动解析

- 设备号: 原始 device_id（如 `A9571617-...`）
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
| 最大团伙 | 4,936 节点（963 设备 / 2,503 账号 / 4,135 证件） |

> 详细结果见 `docs/09_execution_results.md`

## 关键决策点
1. 首版只用机票 + 客诉，跑通后再扩酒店/门票
2. 标签阈值见 docs/02_field_design.md 第五节，需人工抽检后调整
3. 监督版模型 PR-AUC ≥ 0.6 才上线，否则用规则版
4. 无正负样本时用伪标签（强规则生成）训练监督模型，AP=1.0 是预期结果
5. Leiden 构图范围默认仅高风险设备，可改 `RISK_ONLY=False` 扩到全量
6. 团伙查询服务的邻接表加载约需 10-20s，首次启动请耐心等待 tqdm 进度条

## 版本管理（Git）

项目已纳入 Git 版本控制，支持回退和协作。仓库地址：
`https://github.com/Apostroph-1/Leiden_risk_user_identification.git`

### 当前版本

| 标签 | 说明 |
|------|------|
| v1.0 | 离线风险用户识别 + Leiden 团伙识别 + 多模型分层 + 前端可视化 |
| v1.1 | 社区指标模块 + git 版本管理 |
| v1.2 | 修复社区图谱TDZ bug + 分页跳转 + 度数说明 |
| v1.3 | 删除团伙列表模块 + 社区指标增强(社区ID搜索+设备下钻+支付索引排序) + 高危社区行为分析 + 模块改动手册 |

### 常用命令

```bash
git log --oneline          # 查看提交历史
git tag                    # 查看所有版本标签
git checkout v1.0          # 回退到 v1.0（保留工作区修改）
git reset --hard v1.0      # 彻底回退到 v1.0（丢弃所有修改）
```

### 发布新版本

```bash
git add -A
git commit -m "v1.2: 新功能描述"
git tag v1.2
git push origin main --tags
```

---

## 联系
- 数据：本人
- 业务方：待补充
