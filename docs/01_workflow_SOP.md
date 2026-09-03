# 11. 全量操作 SOP

> 适用场景：从原始宽表 CSV 到"风险分层 → 社群识别 → 合并输出 → 可视化查询"全流程
> 前置条件：Python 3.10+ 环境且依赖已安装
> 预计耗时：20-30 分钟（全部 865K 设备）

---

## 一、环境准备

### 1.1 Python 依赖

```bash
pip install -r requirements.txt
```

依赖清单:

| 包 | 用途 | 可选 |
|----|------|------|
| pandas / numpy | 数据读写、数值计算 | 必选 |
| scikit-learn | iForest / OC-SVM / LOF / RF / 决策树 / StandardScaler | 必选 |
| xgboost | 监督模型 XGBoost | 必选（缺失则跳过该模型） |
| lightgbm | 监督模型 LightGBM | 必选（缺失则跳过该模型） |
| shap | SHAP 可解释性分析 | 可选（缺失则跳过可解释性） |
| igraph + leidenalg | Leiden 社群检测 | 必选（01 notebook） |
| tqdm | 进度条 | 必选 |
| joblib | 模型持久化 | 必选 |
| matplotlib / seaborn | 图表生成 | 可选 |
| nbformat | nb_generator.py 重建 .ipynb | 仅重建 notebook 时需要 |

### 1.2 数据文件准备

将设备维度宽表 CSV 放到 data/ 目录：

```
data/
  flight_feature_detail_8.19-90days.csv   <- 原始数据（282MB, 865K 设备）
```

如果要换一批数据，只需将新 CSV 放到 data/ 下，然后修改 notebook 中 INPUT_CSV 变量指向新文件即可。

### 1.3 输出目录

所有操作自动写入 data/model_output/（首次运行自动创建）：

```
data/model_output/
  device_risk_score.csv       <- 02 输出：设备风险分层结果
  exploded_edges.csv           <- 01 输出：展开后的边表
  device_community.csv        <- 01 输出：节点层级社区归属
  gang_list.csv               <- 01 输出：团伙列表
  graph_adjacency.json        <- 01 输出：邻接表（查询服务用）
  final_merged_output.csv     <- 03 输出：合并后最终表
  community_analysis.csv      <- 01 输出：高危社区行为分析
  xgb.pkl / lgb.pkl / rf.pkl  <- 训练得到的模型
  shap_summary.png            <- SHAP 图
  tree_rules.txt / .png       <- 决策树规则
  model_correlation.png       <- 模型相关性热力图
  risk_level_distribution.png <- 4 级分布柱状图
```

---

## 二、执行流程总览

```
02 多模型分层  ->  01 Leiden 社群  ->  03 合并输出  ->  查询可视化
(notebook)         (notebook)          (notebook)       (server)
    |                  |                    |                |
    v                  v                    v                v
device_risk       exploded_edges       final_merged      前端页面
_score.csv        device_community     _output.csv       http://127.0.0.1:8766
                  gang_list
                  graph_adjacency.json
```

执行顺序严格为 02 → 01 → 03 → 启动服务

> **注意**：01 (Leiden) 依赖 02 的 device_risk_score.csv 中的 risk_level 列来筛选高危设备。

---

## 三、分步操作指南

### 步骤 1: 多模型风险分层（02_multi_model_stratify.ipynb）

目标：对 865K 设备进行 6 模型加 7 规则风险分层，输出 4 级分层。

操作：

1. 在 VSCode 中打开 notebooks/02_multi_model_stratify.ipynb
2. 检查 Cell 1 中 INPUT_CSV 路径是否指向正确数据文件
3. 依次执行每个 cell

关键可调参数（搜索 `[TUNABLE]` 标记）:

| 参数 | 默认值 | 修改影响 |
|------|--------|----------|
| INPUT_CSV | 数据路径 | 换数据时修改 |
| SAMPLE_N | None（全量） | 设小值快速测试 |
| is_short_refund_strong | <= 600s | 极可疑退款时间阈值 |
| is_short_refund_weak | 600s < x <= 3600s | 弱信号退款时间阈值 |
| is_machine_refund | cardinality diff > 0 AND refund_rate > 0.5 | 机器退款判定 |
| is_night_heavy | >= 0.5 | 凌晨单占比阈值（P95） |
| is_multi_account | >= 2 | 多账号判定 |
| is_multi_pay_tool | >= 3 | 多支付索引判定 |
| is_multi_passenger | >= 5 | 多乘机人证件判定 |
| iForest n_estimators | 200 | 树数量 |
| OC-SVM sample_n | 20000 | SVM 训练采样量 |
| OC-SVM nu | 0.1 | 异常比例上限 |
| LOF n_neighbors | 50 | 局部密度邻居数 |
| XGB n_estimators | 300 | 监督模型树数量 |
| LGB n_estimators | 300 | 监督模型树数量 |
| RF n_estimators | 200 | 监督模型树数量 |
| 分层阈值 | 0.6/2, 2/1, 1/1 | 高/中/疑 三个等级分界点 |

验证检查点（Cell 末尾输出）：
- device_risk_score.csv 行数 = 原始数据行数
- 4 级分层分布合理（高风险 1-5%）
- 7 条规则列全部存在

### 步骤 2: Leiden 社群识别（01_leiden_community.ipynb）

目标：将高危设备按 user_id / pay_tool / 乘机人证件 / 乘机人手机展开为多行，构建图并运行 Leiden 社群检测。

操作：

1. 打开 notebooks/01_leiden_community.ipynb
2. 检查 Cell 1 中路径配置
3. 依次执行每个 cell

关键可调参数:

| 参数 | 默认值 | 修改影响 |
|------|--------|----------|
| RISK_FILTER | high_risk | 社群检测仅对高风险设备（缩小图规模） |
| MIN_COMMUNITY_SIZE | 3 | 最小社区节点数 |
| PAY_TOOL_FIELD | flight_pay_tool_detail | 支付索引字段名 |

验证检查点：
- exploded_edges.csv 边数 > 0
- device_community.csv 设备节点数与筛选后高危设备数一致
- graph_adjacency.json 非空

### 步骤 3: 合并输出（03_merge_output.ipynb）

目标：将原始宽表 + 社区归属 + 风险评分合并为一张最终表。

操作：

1. 打开 notebooks/03_merge_output.ipynb
2. 依次执行每个 cell

验证检查点：
- final_merged_output.csv 行数 = 原始数据行数（去重后）
- 列顺序：device_id → community_id → 原始字段 → 规则+模型+投票+分层
- community_id 非空率 = 高危设备占比

### 步骤 4: 启动前端查询服务

```bash
"D:/Users/yubotai.gao/coding/python/python.exe" tools/community_server.py
```

浏览器访问 http://127.0.0.1:8766

---

## 四、Notebook 修改流程

### 4.1 修改代码

1. 修改 notebooks/ 下的 `XX_cells.txt` 文件（这是源码）
2. 运行 nb_generator.py 重新生成 .ipynb：

```bash
"D:/Users/yubotai.gao/coding/python/python.exe" notebooks/nb_generator.py notebooks/02_cells.txt notebooks/02_multi_model_stratify.ipynb
```

3. 在 VSCode 中打开 .ipynb 逐 cell 执行验证

### 4.2 cells.txt 格式

```
##MD##
（markdown 说明）
##CODE##
（python 代码）
##MD##
（下一节说明）
##CODE##
（下一节代码）
```

- `##MD##` 标记 markdown cell
- `##CODE##` 标记 code cell
- 两类交替出现

---

## 五、版本管理与 Git

```bash
# 提交更改
git add -A
git commit -m "描述信息"
git push origin main

# 查看历史
git log --oneline

# 回退到某个版本
git checkout <commit-hash>
```

> 注意：data/ 目录下的 CSV 和 XLSX 文件已在 .gitignore 中排除，不会上传原始数据。

---

## 六、常见问题

### Q: device_id 显示为科学计数法？
A: 读取 CSV 时使用 `dtype=str` 参数，不自动检测数据类型。

### Q: OCSVM 训练太慢？
A: 调小 sample_n（默认 20000），或跳过该模型。

### Q: 前端社区图谱为空？
A: 检查 graph_adjacency.json 是否存在且非空；确认 community_server.py 已重启。

### Q: 模型 AP = 1.0 是否过拟合？
A: 伪标签由强规则生成，监督模型学到了规则本身，AP=1.0 是预期行为。关注无监督模型异常数差异和 SHAP 重要性排序的合理性。

### Q: 如何增加新的业务线指标？
A: 在 02 notebook 的 FEATURE_COLS 中添加新字段，确保原始 CSV 包含对应列。参见 docs/12_cross_bizline_metrics_design.md。


---

## v4.2 更新（2026-09-03）

### 全量执行顺序（最新）
```
【本周期】
02 分层 -> 01 Leiden -> 03 合并 -> 06 套利特征 -> 07 航线图 -> 10 指纹团伙 -> 11 舱位套利 -> 08 质检 -> 重启 server

【上周期（演化检测）】
12_prev_stratify.py（读 26.05.29_base.csv）-> 产出 26.05.29_device_risk_score.csv + 26.05.29_midhigh_devices.csv
   -> 上传 temp 表线上跑 02 SQL（START=180/END=90）-> 下载 detail
   -> 09 跃迁检测（P/C 团伙对齐+四形态）-> 重启 server

【真逃离检测】
需以上周期当时中高危名单导出的 detail（26.05.29 版），09 自动识别消失团伙
```

### 产出文件命名规范（2026-09-03 起）
- 周期性产出必须带日期前缀：XX.XX.XX_文件名.csv（如 26.05.29_device_risk_score.csv）
- 中高危名单（上传线上 temp 表用）：XX.XX.XX_midhigh_devices.csv

### 文档体系（2026-09-03 重构后）
- 00_指标口径与算法字典.md —— 唯一权威口径源
- 01_workflow_SOP.md —— 全量操作 SOP（本文档）
- 02_module_workflow_guide.md —— 模块改动手册
- 03_community_behavior_analysis.md —— 高危社区行为特征归纳
- 04_docker_deployment.md —— Docker 部署
- 05_agent_handoff_SOP.md —— Agent 交接
- 06_agent_operating_protocol.md —— Agent 操作协议
- archive/ —— 历史设计稿（旧 01-13 编号，口径已过时仅供参考，git 可追溯）

### 硬规则（每次执行必做）
1. 新增/修改任何指标、字段、算法 -> 同步更新 00 字典
2. 提交 git 前 -> README 版本表更新
3. 跑完管线 -> 08 质检，FAIL 项确认后再发布
4. 前端改动 -> 验证关键 JS 函数存活


### 上周期 base 导出的 HAVING 收紧版（2026-09-03，v4.2）

背景：上周期线上总量 120.6 万台 > 下载上限 100 万，需在线上先过滤普通设备且不漏高危。

收紧原则（已用 26.05.29 已下载的 100 万样本实测验证）：
- 两个过松条件修正：拦截>=1（命中 70.8 万，单次拦截多为误伤）改为 拦截>=2；取消率>50%（命中 54.6 万，低单量普通用户改签噪音）改为 取消率>50% 且 订单>=10
- 增加组合强度：核心信号（赔付/黄牛/快退/多账号/多乘机人）任一命中，或 10 项信号任 2 项同时命中

```sql
having flight_total_order_cnt > 5
and (
    flight_comp_total_amount > 0
    OR flight_min_refund_pay_interval_sec <= 3600
    OR flight_distinct_user_id_cnt >= 2
    OR flight_uid_distinct_card_num_cnt >= 5
    OR flight_scalper_cnt >= 1
    OR (
        (IF(flight_intercept_cnt >= 2,1,0))
        + (IF(flight_distinct_pay_tool_cnt >= 3,1,0))
        + (IF(flight_night_order_cnt * 1.0 / flight_total_order_cnt >= 0.3,1,0))
        + (IF(flight_refund_order_cnt * 1.0 / flight_total_order_cnt > 0.5,1,0))
        + (IF(flight_cancel_order_cnt * 1.0 / flight_total_order_cnt > 0.5 AND flight_total_order_cnt >= 10,1,0))
        + (IF(flight_comp_total_amount > 0,1,0))
        + (IF(flight_min_refund_pay_interval_sec <= 3600,1,0))
        + (IF(flight_distinct_user_id_cnt >= 2,1,0))
        + (IF(flight_uid_distinct_card_num_cnt >= 5,1,0))
        + (IF(flight_scalper_cnt >= 1,1,0))
    ) >= 2
)
```

实测效果：高风险召回 100%（1228/1228）、中高危召回 98.6%（58085/58919）、命中总量约 29.5 万（线上 120 万预估 35.4 万，低于 100 万下载上限）。
