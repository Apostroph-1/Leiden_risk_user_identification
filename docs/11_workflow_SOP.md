# 11. 全流程操作 SOP

> 适用场景: 更换数据文件后重新跑通"风险分类 -> 团伙识别 -> 合并输出 -> 可视化查询"全链路
> 前提条件: Python 3.10+ 环境 + 依赖已安装
> 预计总耗时: 15-25 分钟（全量 865K 设备）

---

## 一、环境准备

### 1.1 Python 环境

```bash
# 确认 Python 版本 >= 3.10
python --version

# 安装依赖（首次运行或更新依赖时执行）
pip install -r python/requirements.txt
```

核心依赖清单:

| 包 | 用途 | 必选 |
|----|------|------|
| pandas / numpy | 数据读写与数值计算 | 必选 |
| scikit-learn | iForest / OC-SVM / LOF / RF / 决策树 / StandardScaler | 必选 |
| xgboost | 监督模型 XGBoost | 可选（缺失则跳过该模型） |
| lightgbm | 监督模型 LightGBM | 可选（缺失则跳过该模型） |
| shap | SHAP 可解释性分析 | 可选（缺失则跳过可解释性） |
| igraph + leidenalg | Leiden 社区发现 | 必选（07 notebook） |
| tqdm | 进度条 | 必选 |
| joblib | 模型持久化 | 必选 |
| matplotlib / seaborn | 图表输出 | 必选 |
| nbformat | nb_generator.py 重建 .ipynb | 仅重建 notebook 时需要 |

### 1.2 数据文件准备

将设备级宽表 CSV 放入 data/ 目录:

```
data/
  flight_feature_detail_8.19-90days.csv   <- 原始宽表（282MB，865K 设备）
```

如果换了一批新数据，只需把新 CSV 放到 data/ 下，然后修改 notebook 的 INPUT_CSV 变量指向新文件即可。

### 1.3 输出目录

所有产出自动写入 data/model_output/（首次运行自动创建）:

```
data/model_output/
  device_risk_score.csv      <- 08 产出：风险分层主表
  exploded_edges.csv          <- 07 产出：展开边表
  device_community.csv       <- 07 产出：节点级社区归属
  gang_list.csv              <- 07 产出：团伙列表
  graph_adjacency.json       <- 07 产出：邻接表（供查询服务）
  final_merged_output.csv    <- 09 产出：合并最终输出
  xgb.pkl / lgb.pkl / rf.pkl <- 训练好的模型
  shap_summary.png           <- SHAP 图
  tree_rules.txt / .png      <- 决策树规则
  model_correlation.png      <- 模型相关性热力图
  risk_level_distribution.png <- 4 级分布柱状图
```

---

## 二、执行流程总览

```
08 风险分类  ->  07 团伙识别  ->  09 合并输出  ->  查询可视化
(notebook)      (notebook)       (notebook)       (server)
    |               |                |               |
    v               v                v               v
device_risk    exploded_edges    final_merged    前端页面
_score.csv     device_community   _output.csv    http://127.0.0.1:8766
(865K,166MB)   gang_list
               graph_adjacency.json
```

执行顺序严格为 08 -> 07 -> 09。07 依赖 08 的 device_risk_score.csv，09 依赖 07 和 08 的产出。不可跳步。

---

## 三、逐步操作指南

### 步骤 1: 多模型风险分类（08_multi_model_stratify.ipynb）

目标: 对 865K 设备进行 6 模型集成分类，输出 4 级风险分层。

操作:

1. 在 VSCode 中打开 notebooks/08_multi_model_stratify.ipynb
2. 检查 Cell 1 的 INPUT_CSV 路径是否指向正确的数据文件
3. 从上到下逐 cell 运行

关键可调参数（搜索 [TUNABLE] 定位）:

| Cell | 参数 | 默认值 | 调整影响 |
|------|------|--------|----------|
| 1 | INPUT_CSV | 宽表路径 | 换数据时改这里 |
| 1 | SAMPLE_N | None（全量） | 设正整数做采样调试（如 10000 快速跑通） |
| 3 | FEATURE_COLS | 54 个特征 | 增删特征影响模型输入维度 |
| 4 | 伪标签规则阈值 | refund_rate>=0.5 等 | 改变正/负样本分布（当前正样本占 47.6%） |
| 5 | n_estimators=200 / contamination=0.1 | iForest | 异常比例 |
| 6 | sample_n=20000 / nu=0.1 | OC-SVM 采样数与异常上界 |
| 7 | n_neighbors=50 | LOF 局部邻域 |
| 8-10 | XGB: n_estimators=300 / max_depth=6 / learning_rate=0.05 | 监督模型超参 |
| 8-10 | LGB: n_estimators=300 / num_leaves=31 | 监督模型超参 |
| 10 | RF: n_estimators=200 / max_depth=10 | 监督模型超参 |
| 12 | 分层阈值: 0.6/2, 2/1, 1/1 | 最重要调参点，直接决定各级别设备数量 |
| 13 | sample_n=3000 | SHAP 采样数（越大越慢） |
| 13 | max_depth=4 | 决策树 surrogate 规则粒度 |

验证检查点（Cell 执行完后确认）:

- Cell 4 打印伪标签分布: 异常约 41 万、正常约 14 万、未标记约 31 万
- Cell 5-7 打印各模型异常数: iForest 约 86K、OC-SVM 约 86K、LOF 约 26K
- Cell 8-10 打印监督模型 AP 值（预期 1.0，因伪标签由规则生成）
- Cell 12 打印 4 级分布: 高风险约 27K（3.1%）、中风险约 219K（25.3%）、疑似风险约 512K（59.2%）、普通约 107K（12.4%）
- 产出文件 data/model_output/device_risk_score.csv（约 166MB）

预计耗时: 3-8 分钟（全量），<30 秒（SAMPLE_N=10000 调试）

---

### 步骤 2: Leiden 团伙识别（07_leiden_community.ipynb）

目标: 将高风险设备按 user_id / pay_tool / 证件 / 手机关联，发现团伙并追踪路径。

前置: 步骤 1 已完成，device_risk_score.csv 已生成。

操作:

1. 在 VSCode 中打开 notebooks/07_leiden_community.ipynb
2. 检查 Cell 1 的 RISK_CSV 路径指向步骤 1 产出的文件
3. 从上到下逐 cell 运行

关键可调参数:

| Cell | 参数 | 默认值 | 调整影响 |
|------|------|--------|----------|
| 1 | INPUT_CSV | 宽表路径 | 换数据时改这里 |
| 1 | RISK_CSV | device_risk_score.csv | 风险分层结果路径 |
| 1 | RISK_ONLY | True | True=仅高风险设备构图（27K设备,快）; False=全量（865K,慢） |
| 1 | MIN_COMMUNITY_SIZE | 3 | 小于此值的社区被筛除 |
| 3 | COLUMN_MAP | user/pay/card/mobile | 增删列调整构图范围 |
| 5 | is_high_risk_gang 条件 | risk_device_rate>=0.5 | 高危团伙标记阈值（见 P1-1） |

验证检查点:

- Cell 1 打印: 高风险设备约 27K 个，仅对 30K 行构图
- Cell 4 打印: 节点约 44 万、边约 42 万、社区约 2.3 万
- Cell 5 打印: 团伙约 23,559 个、高危团伙 23,559 个（全部，因 RISK_ONLY=True）
- Cell 6 打印一条示例路径
- 产出文件: exploded_edges.csv、device_community.csv、gang_list.csv、graph_adjacency.json（约 64MB）

预计耗时: 1-3 分钟

已知问题: 高危团伙标记在 RISK_ONLY=True 时全部为 1（见 docs/10_notebook_code_review.md P1-1）。如需区分团伙优先级，按 community_size 降序排列关注 Top N 即可。

---

### 步骤 3: 合并最终输出（09_merge_output.ipynb）

目标: 将原始宽表 + 社区归属 + 全模型打标合并为一张 CSV。

前置: 步骤 1、2 均已完成。

操作:

1. 在 VSCode 中打开 notebooks/09_merge_output.ipynb
2. 从上到下逐 cell 运行（P0 路径问题已修复）
3. 从上到下逐 cell 运行

验证检查点:

- Cell 1 打印: 原始 865K 行、社区匹配约 27K、风险匹配约 865K
- Cell 3 打印: 最终列数约 79 列
- Cell 4 打印: 输出约 409MB、community_id 非空约 27K（3.1%）
- 产出文件: data/model_output/final_merged_output.csv（约 409MB）

列顺序:

1. device_id -> community_id（紧跟其后）-> 原始宽表全部字段 -> 派生特征 -> 6 模型异常分+打标 -> 投票数+规则命中 -> pseudo_label -> risk_level（最后）

预计耗时: 1-2 分钟

---

### 步骤 4: 启动查询可视化服务（community_server.py）

目标: 提供团伙列表浏览、社区图谱可视化、A-to-B 路径追踪的线上工具。

前置: 步骤 2 已完成，graph_adjacency.json 等文件已生成。

操作:

```bash
python tools/community_server.py
# 默认端口 8766，可 --port 8888 指定
# 首次启动需加载邻接表（约 10-20s），tqdm 显示进度
# 浏览器自动打开 http://127.0.0.1:8766
```

前端功能（5 个页签）:

| 页签 | 功能 |
|------|------|
| 团伙列表 | 分页浏览全部团伙，支持"仅看高危"筛选 |
| 社区图谱 | D3.js 力导向图，滚轮缩放/拖拽平移/可调画布宽高/适应画布，双击节点填入路径查询 |
| 路径查询 | 输入任意两个值，返回 A->B 最短路径，每步标注节点类型和连接关系 |
| 多条路径 | 返回 A->B 之间多条路径（DFS），最多 20 条 |
| 节点查询 | 输入任意值，返回所属社区、度数、邻居列表 |

节点类型与 Tableau 10 色系:

| 节点类型 | 颜色 | 色值 |
|----------|------|------|
| 设备号 | 蓝 | #4E79A7 |
| 用户ID | 橙 | #F28E2B |
| 支付索引 | 绿 | #59A14F |
| 乘机人证件 | 红 | #E15759 |
| 乘机人手机 | 紫 | #B07AA1 |

查询时无需手动加前缀: 输入 device_id 或 user_id 的值即可，服务端自动匹配（设备号无前缀，其他类型自动加 user:: / pay:: / card:: / mobile:: 前缀）。

终止服务: 按 Ctrl+C

---

## 四、Notebook 重建流程

如果直接编辑了 *_cells.txt 源码文件，需要重新生成 .ipynb:

```bash
python notebooks/nb_generator.py notebooks/07_cells.txt notebooks/07_leiden_community.ipynb
python notebooks/nb_generator.py notebooks/08_cells.txt notebooks/08_multi_model_stratify.ipynb
python notebooks/nb_generator.py notebooks/09_cells.txt notebooks/09_merge_output.ipynb
```

文本文件格式:

```
##MD##
（markdown cell 内容）
##CODE##
（code cell 内容）
##MD##
（下一个 markdown cell）
...
```

编辑 txt 文件后运行上述命令即可重建 .ipynb。这比直接编辑 .ipynb 的 JSON 更可靠，避免格式污染。

---

## 五、常见问题与排障

### 5.1 中文乱码

现象: PowerShell 控制台输出中文显示为 GBK 编码乱码。

原因: Windows 控制台默认 GBK 编码，Python 输出 UTF-8 中文时编码不匹配。

解决:
- 文件内容是正确的 UTF-8，不影响 CSV 输出和使用
- 如需控制台正常显示: chcp 65001 或设置环境变量 PYTHONIOENCODING=utf-8
- 所有 CSV 读写统一用 encoding="utf-8-sig"（带 BOM，Excel 可直接打开不乱码）

### 5.2 09 notebook 路径错误

现象: FileNotFoundError，路径多退了一级目录。

原因: P0-1，os.path.abspath("__file__") 在 notebook 中解析为 CWD + "__file__" 字符串，dirname 后路径多退一级。

状态: 已修复（2026-08-21）。原 os.path.abspath("__file__") 已改为硬编码 r"d:/Qunar_work/workbuddy_data/leiden"，notebook 可直接运行。

```python
BASE = r"d:/Qunar_work/workbuddy_data/leiden"
```

### 5.3 内存不足

现象: 865K 行数据全量加载时内存溢出。

解决:
- 08 Cell 1 设 SAMPLE_N = 10000 做采样调试，跑通流程后再改回 None 全量跑
- 确保 16GB 以上内存（全量运行峰值约 6-8GB）
- 07 设 RISK_ONLY = True 只对高风险设备构图（27K vs 865K）

### 5.4 XGBoost / LightGBM 未安装

现象: 打印 XGBoost: False, LightGBM: False

解决:
- 代码已做容错处理，缺失则跳过对应模型，投票时减少投票总数
- 如需完整 6 模型投票: pip install xgboost lightgbm

### 5.5 SHAP 计算失败

现象: SHAP 失败: ...

解决:
- 检查是否安装 shap: pip install shap
- 检查 XGBoost/LightGBM 是否安装（SHAP 用 TreeExplainer 依赖树模型）
- 不影响主流程，风险分层结果不受 SHAP 影响

### 5.6 查询服务加载慢

现象: 启动 community_server.py 后加载 10-20s 无响应。

解决:
- 这是正常行为，邻接表 JSON 约 64MB，加载需 10-20s
- tqdm 进度条会显示加载进度
- 加载完成后浏览器自动打开

### 5.7 查询服务端口被占用

现象: OSError: address already in use

解决: 指定其他端口: python tools/community_server.py --port 8888

### 5.8 节点移出画布可视区域

现象: 在社区图谱中拖拽节点后，节点走出当前画布窗口就无法看到。

解决: 
- 使用画布宽度滑块（800-4000px）和高度滑块（300-3000px）调大画布
- 点击"适应画布"按钮，自动计算所有节点包围盒并缩放平移使图适配当前画布
- 点击"重置缩放"恢复 1:1 视图
- 画布区域支持滚动条（`overflow:auto`），画布大于面板时可滚动查看

---

## 六、数据流与文件依赖图

```
data/flight_feature_detail_8.19-90days.csv (原始宽表, 282MB)
  |
  |--> [08] --> data/model_output/device_risk_score.csv (166MB)
  |                  |-- xgb.pkl / lgb.pkl / rf.pkl
  |                  |-- shap_global_importance.csv / shap_summary.png
  |                  |-- shap_top10_anomaly.csv
  |                  |-- tree_rules.txt / tree_rules.png / tree_surrogate.pkl
  |                  |-- model_comparison.txt
  |                  |-- model_correlation.png / .csv
  |                  `-- risk_level_distribution.png
  |
  |--> [07] --> data/model_output/exploded_edges.csv (边表)
  |   (读 08 的     |-- data/model_output/device_community.csv (节点社区)
  |    device_risk   |-- data/model_output/gang_list.csv (团伙列表)
  |    _score.csv)   `-- data/model_output/graph_adjacency.json (64MB, 邻接表)
  |
  `--> [09] --> data/model_output/final_merged_output.csv (409MB)
       (读原始宽表      列: device_id | community_id | 原始字段 | 派生特征 |
        + 07 + 08)            6模型分 | 投票 | pseudo_label | risk_level

[tools/community_server.py] --> 读 07 产出 --> HTTP API (端口 8766)
                                    |
                                    `--> tools/community_viz.html (D3 前端)
```

---

## 七、全流程快速命令

以下为命令行一键执行（不使用 notebook，适合无人值守跑批）:

```bash
# 步骤 1: 多模型风险分类（命令行版，无 tqdm 进度条）
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/08_multi_model_stratify.py

# 步骤 2: Leiden 团伙识别
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/07_leiden_community.py --risk-only --min-community-size 3

# 步骤 3: 合并最终输出
"D:/Users/yubotai.gao/coding/python/python.exe" -u python/09_merge_output.py

# 步骤 4: 启动查询服务
python tools/community_server.py
```

推荐做法: 首次运行和调参时用 notebook（有 tqdm 进度条和中间输出，便于调试）；确认参数后批量跑批用 .py 命令行版。

---

## 八、调参速查

### 8.1 想改变高风险设备数量

修改 08 Cell 12（分层阈值，最重要调参点）:

```python
# 当前: 高风险 = vote>=60% AND rule_hit>=2
# 放宽（更多高风险）: vote>=50% AND rule_hit>=1
# 收紧（更少高风险）: vote>=70% AND rule_hit>=3
```

### 8.2 想改变团伙数量

修改 07 Cell 1:

```python
RISK_ONLY = True    # False = 全量构图，更多设备更多团伙
MIN_COMMUNITY_SIZE = 3  # 改大 = 更少更集中的团伙
```

### 8.3 想增加构图维度

修改 07 Cell 3 的 COLUMN_MAP:

```python
# 当前: user / pay / card / mobile
# 可加: IP（如果有明细）、email 等
COLUMN_MAP = [
    ("flight_distinct_user_id",      "user"),
    ("flight_pay_tool_detail",       "pay"),
    ("flight_uid_card_info",         "card"),
    ("flight_passenger_mobile_info", "mobile"),
    # ("flight_distinct_email",      "email"),  # 取消注释即可加入
]
```

### 8.4 想调整伪标签正样本比例

修改 08 Cell 4 的强规则阈值:

```python
# 当前正样本 47.6%，想减少:
# - flight_distinct_user_id_cnt >= 5  ->  >= 8
# - flight_intercept_cnt >= 2        ->  >= 3
# - 增加复合条件: AND flight_total_order_cnt >= 20
```

### 8.5 想调试时快速跑通

修改 08 Cell 1:

```python
SAMPLE_N = 10000  # 采样 1 万行，30 秒跑通全流程
```

确认流程无误后改回 SAMPLE_N = None 全量运行。

---

## 九、检查清单

每次跑完全流程后，逐项确认:

- [ ] device_risk_score.csv 行数约 865K，risk_level 有 4 个值
- [ ] gang_list.csv 团伙数约 23K，is_high_risk_gang 全为 1（RISK_ONLY=True 时的预期行为）
- [ ] final_merged_output.csv 约 857K 行 x 79 列，community_id 列紧跟 device_id，risk_level 在最后
- [ ] final_merged_output.csv 中 community_id != -1 的行约 27K（高风险设备有社区归属）
- [ ] 查询服务可启动，团伙列表可分页，路径查询可返回结果
- [ ] SHAP 图、决策树规则图、模型相关性热力图、4 级分布图均已生成
- [ ] xgb.pkl / lgb.pkl / rf.pkl 模型文件已保存

---

## 十、后续迭代方向

1. 全部 P0/P1/P2 问题已修复（含两轮修复），详见 docs/10_notebook_code_review.md
2. 画布可视化已增强: 宽高双向可调 + 适应画布功能，节点不会丢失
3. 伪标签已收紧: >= 5 改为 >= 8 AND >= 20 单; >= 2 改为 >= 3（预计正样本 25-35%，需重跑验证）
4. 扩展业务线: 接入酒店/门票数据后，跨业务线构图可发现跨线团伙
5. IP 维度入图: 当前 IP 仅有计数无明细，需回原始订单表取 IP 明细加入构图
6. Gephi 可视化: graph_edges.csv 可直接导入 Gephi 做高级团伙可视化
7. 上线风险分: device_risk_score.csv 可导 MySQL 供 Tableau 展示

---

## 十一、修复记录（2026-08-21）

代码评审发现的所有 P0/P1/P2 问题已全部修复（含两轮），详见 [docs/10_notebook_code_review.md](/D:/Qunar_work/workbuddy_data/leiden/docs/10_notebook_code_review.md) 第五、六节。修复覆盖 cells.txt 源码、重新生成的 .ipynb、.py 命令行版本、以及前端 HTML。重跑全流程即可验证。

第二轮修复（R2-1 ~ R2-7）额外修复了:
- 07 .py 的 IndentationError（死代码 + 缩进错误）
- community_viz.html 画布宽高双向调节和适应画布功能
- 08 .py 的 pos_w 变量作用域问题
- 07 .py 的 exploded_edges.csv / graph_adjacency.json 输出和社区重编号
