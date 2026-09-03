# 模块改动手册

> 本文档说明项目各模块的职责、修改方式，以及如何从离线 CSV 切换到 API/数据库连接。

## 项目架构总览

```
数据源（离线CSV / API / DB）
  |
  v
特征工程（python/01 或 notebooks/08）→ device_risk_score.csv
  |
  v
多模型投票分层（notebooks/08）→ risk_level + 6模型打标
  |
  v
Leiden 团伙识别（python/07 或 notebooks/07）→ community_id + 图数据
  |
  v
合并输出（notebooks/09）→ final_merged_output.csv
  |
  v
查询服务（tools/community_server.py）→ 前端可视化（tools/community_viz.html）
```

## 各模块修改指南

### 1. 数据输入模块

**当前**：读取 `data/flight_feature_detail_8.19-90days.csv` 离线 CSV

**改为 API/DB 连接**：

在 `notebooks/08_multi_model_stratify.ipynb` 的 Cell 1 中，将：

```python
INPUT_CSV = "data/flight_feature_detail_8.19-90days.csv"
df = pd.read_csv(INPUT_CSV, encoding="utf-8-sig")
```

替换为以下三种方案之一：

#### 方案 A：直连数据库（MySQL/StarRocks）

```python
import pymysql  # 或 starrocks connector
conn = pymysql.connect(host="10.x.x.x", port=3306, user="xxx",
                       password="xxx", database="dws", charset="utf8mb4")
SQL = '''
SELECT device_id, flight_total_order_cnt, flight_pay_ok_order_cnt, ...
FROM dws_device_flight_feature
WHERE dt >= DATE_SUB(CURDATE(), INTERVAL 90 DAY)
  AND flight_total_order_cnt > 5
'''
df = pd.read_sql(SQL, conn)
conn.close()
```

#### 方案 B：通过 API 获取

```python
import requests
resp = requests.post("http://your-api-host/api/device_features", json={
    "start_date": "2026-05-29",
    "end_date": "2026-08-26",
    "min_orders": 5,
    "biz_line": "flight"
})
data = resp.json()
df = pd.DataFrame(data["rows"])
```

#### 方案 C：SQL 文件 + 命令行导出

```bash
# 在 sql/ 目录下写 SQL，用命令行导出 CSV
mysql -h 10.x.x.x -u xxx -p dws -e "SELECT ..." > data/flight_features.csv
```

**修改范围**：仅 Cell 1 的数据加载部分
**影响**：下游所有 cell 不受影响（df 变量结构不变）

### 2. 特征工程模块（python/01_feature_engineering.py）

**职责**：从 DWD 表聚合到设备级宽表
**修改方式**：修改 SQL 查询中的聚合逻辑和字段列表
**关键文件**：`sql/05_device_sql.sql` 中的 DWS 聚合 SQL

### 3. 模型训练模块（notebooks/08_multi_model_stratify.ipynb）

**职责**：6 模型投票 + 4 级风险分层
**修改位置**：搜索 `[TUNABLE]` 标记

| 参数 | Cell | 默认值 | 修改影响 |
|------|------|--------|----------|
| SAMPLE_N | Cell 1 | None | 采样调试，设正整数 |
| FEATURE_COLS | Cell 7 | 30+特征 | 增删特征列 |
| 伪标签阈值 | Cell 9 | refund_rate>0.5 等 | 改变正/负样本分布 |
| iForest n_estimators | Cell 11 | 200 | iForest 树数量 |
| iForest contamination | Cell 11 | 0.1 | 预期异常比例 |
| OC-SVM sample_n | Cell 13 | 20000 | 采样数 |
| OC-SVM nu | Cell 13 | 0.1 | 异常上界 |
| LOF n_neighbors | Cell 15 | 50 | 局部邻域大小 |
| XGB n_estimators | Cell 17 | 300 | 树数量 |
| XGB max_depth | Cell 17 | 6 | 树深度 |
| LGB n_estimators | Cell 19 | 300 | 树数量 |
| LGB num_leaves | Cell 19 | 31 | 叶节点数 |
| RF n_estimators | Cell 21 | 200 | 树数量 |
| RF max_depth | Cell 21 | 10 | 树深度 |
| 分层阈值 | Cell 27 | 0.6/2, 2/1, 1/1 | 各级别设备数量 |

### 4. Leiden 团伙识别模块（notebooks/07_leiden_community.ipynb）

**职责**：展开多值列 → 构图 → Leiden 社区发现 → 路径追踪
**修改位置**：搜索 `[TUNABLE]` 标记

| 参数 | Cell | 默认值 | 修改影响 |
|------|------|--------|----------|
| RISK_ONLY | Cell 1 | True | True=仅高风险设备构图 |
| MIN_COMMUNITY_SIZE | Cell 1 | 3 | 小于该值的社区被筛除 |
| 列映射 | Cell 7 | user/pay/card/mobile | 增删构图范围 |

### 5. 查询服务模块（tools/community_server.py）

**职责**：HTTP API + BFS 路径追踪 + 社区指标聚合
**新增 API**：

| 端点 | 说明 |
|------|------|
| `GET /api/device_detail/<device_id>` | 设备下钻明细（userId/手机/支付索引/证件） |
| `GET /api/community_detail/<id>?sort=pay_tool` | 社区设备明细，默认按支付索引个数降序 |

**修改方式**：
- 新增聚合指标：在 `get_community_metrics()` 的 `sum_cols` / `mean_cols` 列表中添加字段名
- 新增下钻字段：在 `load()` 的 `usecols` 列表中添加字段名，然后在 `get_device_detail()` 中添加返回
- 修改排序规则：在 `get_community_detail()` 的 `sort_map` 中添加排序选项

### 6. 前端模块（tools/community_viz.html）

**职责**：D3.js 力导向图 + 6 个功能页签
**当前页签**：社区指标（默认）、社区图谱、路径查询、多条路径、节点查询

**修改方式**：
- 新增页签：在 `.tabs` div 中添加 `<div class="tab" data-tab="xxx">标签</div>`，在 `.panel` 中添加 `<div class="panel" id="panel-xxx">`
- 修改图表样式：CSS 变量在 `<style>` 块顶部，Tableau 10 色系已定义为常量
- 新增交互：在 `<script>` 块中添加 JS 函数，调用 `/api/xxx` 端点

## 从离线表切换到在线 API 的完整方案

### Step 1：编写数据 API

```python
# 在企业内部 API 服务中新增端点
@app.route("/api/device_features")
def device_features():
    sql = "SELECT * FROM dws_device_flight_feature WHERE dt >= %s"
    df = pd.read_sql(sql, conn, params=[start_date])
    return jsonify({"rows": df.to_dict("records")})
```

### Step 2：修改 notebook 数据加载

将 Cell 1 的 `pd.read_csv(...)` 替换为 `pd.read_sql(...)` 或 `requests.get(...)`。
其余 cell 无需修改。

### Step 3：修改查询服务数据加载

在 `community_server.py` 的 `GraphEngine.load()` 中，将 `pd.read_csv(merged_path)` 替换为 API 调用或 DB 查询。

### Step 4：部署到服务器

```bash
# 1. 克隆仓库
git clone https://github.com/Apostroph-1/Leiden_risk_user_identification.git
cd Leiden_risk_user_identification

# 2. 安装依赖
pip install -r requirements.txt

# 3. 运行建模（或直接加载已有模型输出）
python python/08_multi_model_stratify.py
python python/07_leiden_community.py --risk-only

# 4. 启动查询服务
python tools/community_server.py --port 8766

# 5. Nginx 反向代理（可选）
# location /risk/ { proxy_pass http://127.0.0.1:8766/; }
```

## 常见修改场景

### Q: 如何增加酒店业务线指标？

1. 在数据输入阶段增加酒店字段（`hotel_total_order_cnt` 等）
2. 在 `FEATURE_COLS` 列表中添加新特征
3. 在查询服务的 `usecols` 和 `sum_cols` 中添加新字段
4. 在前端的表格中添加新列

### Q: 如何调整风险分层阈值？

在 `notebooks/08` Cell 27 中修改：

```python
# [TUNABLE] 分层阈值 - 最重要调参点
HIGH_RISK_VOTE_RATIO = 0.6   # 投票异常比例阈值
HIGH_RISK_RULE = 2            # 规则命中数阈值
MID_RISK_VOTE = 2             # 中风险投票数
MID_RISK_RULE = 1              # 中风险规则数
```

### Q: 如何修改社区构图范围？

在 `notebooks/07` Cell 7 中增删列映射：

```python
# [TUNABLE] 构图列 - 增删调整构图范围
ENTITY_COLS = {
    "flight_distinct_user_id": "user",      # userId
    "flight_pay_tool_detail": "pay",        # 支付索引
    "flight_uid_card_info": "card",         # 证件
    "flight_passenger_mobile_info": "mobile", # 手机
    # "flight_distinct_ip": "ip",            # 取注释可加入IP
}
```
