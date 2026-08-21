# 机票设备号风险分类方案（无监督 + 可解释 + Leiden 团伙识别）

> 数据：`flight_feature_detail_8.19-90days.csv`（865,389 个设备，T-90d 聚合，>5 单）
> 无正负样本 → 无监督异常检测 + 聚类细分 + SHAP 可解释
> 最终目标：Leiden 算法做团伙社区发现

---

## 一、整体流程

```
[原始宽表 865K]
       ↓ 规则预筛选（剔除明显正常设备，减少计算量）
[候选高危池 ~50K]
       ↓ Isolation Forest 异常检测
[异常设备 ~5K]
       ↓ K-Means 聚类细分风险类型
[4-6 个风险簇]
       ↓ SHAP + 决策树 surrogate 解释
[可解释风险标签 + 风险分]
       ↓ 构建图网络（设备-账号-支付工具-IP-乘机人）
[Leiden 团伙社区发现]
[团伙列表 + 团伙规模]
```

---

## 二、分层方案

### 第一层：规则预筛选（粗筛）

**目的**：从 865K 设备中筛出"有风险行为"的候选池，减少后续计算量。

**规则**（任一命中即入选候选池）：

| 规则 | 阈值 | 依据 |
|---|---|---|
| R1 退款率高 | refund_order_cnt/total_order_cnt ≥ 0.3 | 退款滥用 |
| R2 赔付金额大 | comp_total_amount ≥ 100 | 已产生赔付 |
| R3 多账号聚集 | distinct_user_id_cnt ≥ 2 | 同设备多账号 |
| R4 多支付工具 | distinct_pay_tool_cnt ≥ 3 | 支付工具聚集 |
| R5 黄牛标记 | scalper_cnt ≥ 1 | 已识别黄牛 |
| R6 被拦截 | intercept_cnt ≥ 1 | 已被风控 |
| R7 多乘机人 | uid_distinct_card_num_cnt ≥ 5 | 代购识别 |
| R8 多IP | distinct_ip_cnt ≥ 10 | IP聚集 |
| R9 夜间下单多 | night_order_cnt ≥ 3 | 夜间异常 |
| R10 短间隔退款 | min_refund_pay_interval_sec ≤ 3600 | 秒退 |
| R11 退款时间差多样性低 | cardinality_refund_pay_time_diff == 1 AND refund_order_cnt ≥ 5 | 机器操作 |
| R12 大额赔付 | comp_total_amount ≥ 500 | 大额赔付 |

> 阈值基于数据分布（75 分位）调整，可调。

### 第二层：Isolation Forest 异常检测

**算法**：Isolation Forest（iForest）
- 无监督，不需要标签
- 原理：随机选特征 + 随机选分割值，异常点路径短（容易被孤立）
- 输出：anomaly_score ∈ [0,1]，越大越异常
- 参数：n_estimators=200, contamination=0.1（预期 10% 异常）
- 优势：对高维数据友好，时间复杂度低

**输入特征**（见第三节特征工程）

**输出**：每个候选设备的异常分 + 是否异常（top 10%）

### 第三层：K-Means 聚类细分风险类型

**目的**：异常设备内部不是同质的，需细分风险类型。

**算法**：K-Means + 轮廓系数选 K
- K 范围：4-8，选轮廓系数最大的
- 输入：异常设备的特征（标准化后）
- 输出：每个异常设备的簇标签（风险类型）

**预期簇含义**（由解释后命名）：
- 簇 1：退款滥用型（高退款率、短间隔退款）
- 簇 2：多账号薅羊毛型（多账号、多支付工具、低单价）
- 簇 3：黄牛代购型（多乘机人、多航班、低折扣）
- 簇 4：赔付滥用型（高赔付金额、多客诉）
- 簇 5：机器刷单型（退款时间差多样性低、夜间下单多）

### 第四层：可解释性

**方法 1：SHAP（主解释器）**
- 用 SHAP 计算 Isolation Forest 每个特征的贡献
- 输出：每个设备的 top 3 异常原因（SHAP value 最大的特征）
- 优点：局部可解释，知道"为什么这个设备被判定为异常"

**方法 2：决策树 surrogate（全局解释）**
- 用决策树拟合 Isolation Forest 的输出（异常/正常）
- 树深度 4，可可视化
- 优点：全局规则化，知道"模型整体怎么判的"
- 输出：规则路径如 `refund_rate ≥ 0.5 AND distinct_user_id ≥ 3 → 异常`

**方法 3：簇特征雷达图**
- 每个簇的特征均值 vs 全体均值
- 雷达图可视化，直观看每类风险的画像

---

## 三、特征工程

### 3.1 派生特征（在原始字段基础上计算）

| 派生特征 | 公式 | 含义 |
|---|---|---|
| `refund_rate` | refund_order_cnt / total_order_cnt | 退款率 |
| `refund_amount_rate` | refund_amount / pay_ok_order_amount | 退款金额率 |
| `comp_amount_rate` | comp_total_amount / pay_ok_order_amount | 赔付金额率 |
| `cancel_rate` | cancel_order_cnt / total_order_cnt | 取消率 |
| `gq_rate` | gq_order_cnt / total_order_cnt | 改签率 |
| `ticket_success_rate` | ticket_success_order_cnt / total_order_cnt | 出票成功率 |
| `voucher_order_rate` | voucher_order_cnt / total_order_cnt | 用券订单率 |
| `avg_order_amount` | pay_ok_order_amount / pay_ok_order_cnt | 单均金额 |
| `user_per_order` | distinct_user_id_cnt / total_order_cnt | 单均账号数 |
| `pay_tool_per_order` | distinct_pay_tool_cnt / total_order_cnt | 单均支付工具数 |
| `ip_per_order` | distinct_ip_cnt / total_order_cnt | 单均IP数 |
| `passenger_per_order` | uid_distinct_card_num_cnt / total_order_cnt | 单均乘机人数 |
| `mobile_per_order` | uid_distinct_passenger_mobile_cnt / total_order_cnt | 单均乘机人手机数 |
| `is_short_refund` | min_refund_pay_interval_sec ≤ 3600 ? 1 : 0 | 是否秒退 |
| `is_machine_refund` | (cardinality_refund_pay_time_diff == 1 AND refund_order_cnt ≥ 5) ? 1 : 0 | 是否机器退款 |
| `is_night_heavy` | night_order_cnt / total_order_cnt ≥ 0.3 ? 1 : 0 | 是否夜间高频 |
| `is_multi_account` | distinct_user_id_cnt ≥ 2 ? 1 : 0 | 是否多账号 |
| `is_multi_pay_tool` | distinct_pay_tool_cnt ≥ 3 ? 1 : 0 | 是否多支付工具 |
| `is_multi_passenger` | uid_distinct_card_num_cnt ≥ 5 ? 1 : 0 | 是否多乘机人 |
| `scalper_rate` | scalper_cnt / total_order_cnt | 黄牛单比例 |
| `intercept_rate` | intercept_cnt / total_order_cnt | 拦截比例 |

### 3.2 入模特征清单（数值型 + 派生）

**规模类**：total_order_cnt, pay_ok_order_cnt, pay_ok_order_amount, pay_tool_size
**比率类**：refund_rate, refund_amount_rate, comp_amount_rate, cancel_rate, gq_rate, ticket_success_rate, voucher_order_rate, scalper_rate, intercept_rate
**聚集类**：distinct_user_id_cnt, distinct_username_cnt, distinct_mobile_cnt, distinct_email_cnt, distinct_pay_tool_cnt, distinct_ip_cnt, uid_distinct_card_num_cnt, uid_distinct_passenger_mobile_cnt
**单价/比值**：avg_order_amount, user_per_order, pay_tool_per_order, ip_per_order, passenger_per_order, mobile_per_order
**价格风险**：avg_discount, min_discount, bottom_price_order_cnt, add_price_sum, pricedepth_sum, voucher_sum, express_price_sum, service_fee_sum, exp_cut_sum
**行为**：pre_day_avg, flight_size_avg, combine_order_cnt, distinct_dep_city_cnt, distinct_arr_city_cnt, night_order_cnt, weekend_order_cnt
**时效**：min_refund_pay_interval_sec, max_refund_pay_interval_sec, avg_refund_pay_interval_sec, cardinality_refund_pay_time_diff
**标记**：is_short_refund, is_machine_refund, is_night_heavy, is_multi_account, is_multi_pay_tool, is_multi_passenger
**赔付**：comp_total_amount

> 不入模字段：device_id（主键）、flight_distinct_user_id / flight_uid_card_info / flight_passenger_mobile_info（明细字符串，用于后续团伙识别）、flight_pay_tool_detail（明细字符串）

### 3.3 缺失值处理
- 数值缺失（如 min_refund_pay_interval_sec 对无退款设备为空）：填充大值（如 999999）表示"不接近异常"
- 比率字段分母为 0 时填 0

### 3.4 标准化
- Isolation Forest：不需要标准化（树模型对尺度不敏感）
- K-Means：需要 StandardScaler 标准化

---

## 四、Leiden 团伙识别

### 4.1 时机
- 在风险分类完成后，对"高危设备"及其关联的账号/IP/支付工具/乘机人构图
- 也可对全量设备构图，但计算量大，建议先对高危设备

### 4.2 图网络构建

**节点类型**：
- device_id（设备）
- user_id（账号）
- pay_tool_id（支付工具索引）
- ip（IP）
- passenger_card_num（乘机人证件号）
- passenger_mobile（乘机人手机）

**边**：
- device_id — user_id（设备使用过该账号）
- device_id — pay_tool_id（设备使用过该支付工具）
- device_id — ip（设备使用过该 IP）
- device_id — passenger_card_num（设备下过该乘机人）
- device_id — passenger_mobile（设备用该乘机人手机）

**边权**：订单数（共下过几单）

**来源**：从宽表的明细字段展开：
- `flight_distinct_user_id`（形如 ["A","B"]）→ user_id 列表
- `flight_pay_tool_detail`（形如 ["A","B"]）→ pay_tool_id 列表
- `flight_uid_card_info` → passenger_card_num 列表
- `flight_passenger_mobile_info` → passenger_mobile 列表
- IP 无明细字段（仅有 distinct_ip_cnt 计数），需回原始订单表取

### 4.3 Leiden 算法

**库**：python-igraph 或 leidenalg
- `import igraph as ig`
- `import leidenalg`

**步骤**：
1. 构建图（节点去重、边加权）
2. 跑 Leiden 算法：`leidenalg.find_partition(G, leidenalg.ModularityVertexPartition)`
3. 输出：每个节点的 community_id
4. 分析：community_size ≥ 3 的团伙为可疑团伙

**输出表**：
- `device_id, community_id, community_size, community_node_types`
- 高危设备 + 所属团伙

### 4.4 团伙风险评估
- 团伙规模 ≥ 5：高风险团伙
- 团伙内高危设备占比 ≥ 50%：高风险团伙
- 团伙跨多业务线（后续接酒店/门票）：跨线团伙

---

## 五、执行计划

| 步骤 | 产出 | 脚本 |
|---|---|---|
| 1. 数据加载 + 派生特征 | df_with_features.csv | `python/06_unsupervised_risk_model.py` step1 |
| 2. 规则预筛选 | candidate_devices.csv | step2 |
| 3. Isolation Forest | iforest_result.csv | step3 |
| 4. K-Means 聚类 | cluster_result.csv | step4 |
| 5. SHAP 解释 | shap_explanation.csv + 图 | step5 |
| 6. 决策树 surrogate | tree_rules.png + rules.txt | step6 |
| 7. 风险分 + 标签 | device_risk_score.csv | step7 |
| 8. Leiden 团伙 | device_community.csv + 团伙列表 | `python/07_leiden_community.py` |

---

## 六、风险分计算

最终输出每个设备的综合风险分 0-100：

```
risk_score = 
    50 * iforest_anomaly_score（归一化到0-1）
  + 30 * (1 - silhouette_to_cluster_center)（聚类紧密度）
  + 20 * rule_hit_count_normalized（规则命中数）
```

风险等级：
- 0-30：低风险
- 30-70：中风险
- 70-100：高风险

---

## 七、可解释性输出示例

### 7.1 SHAP 局部解释（单设备）
```
device_id: a9c2e407c9b1bc4f
风险分: 87 (高风险)
簇: 簇2-多账号薅羊毛型
Top3 异常原因:
  1. distinct_user_id_cnt = 10 (SHAP +0.23)
  2. refund_rate = 0.82 (SHAP +0.18)
  3. avg_order_amount = 356 (SHAP +0.12)
```

### 7.2 决策树全局规则
```
IF refund_rate >= 0.5 AND distinct_user_id_cnt >= 2 THEN 异常 (precision 0.85, coverage 0.32)
IF comp_total_amount >= 200 AND scalper_cnt >= 1 THEN 异常 (precision 0.91, coverage 0.15)
IF is_machine_refund = 1 THEN 异常 (precision 0.78, coverage 0.08)
```

### 7.3 簇画像
```
簇1-退款滥用型 (n=1200):
  refund_rate 均值 0.65 (全体 0.07)
  min_refund_pay_interval_sec 均值 1800s (全体 999999)
  avg_order_amount 均值 1200 (全体 3500)
```

---

## 八、依赖

```
pandas
numpy
scikit-learn  # IsolationForest, KMeans, DecisionTree
shap          # SHAP 解释
igraph        # 图网络
leidenalg     # Leiden 社区发现
matplotlib    # 可视化
joblib        # 模型保存
```

本地 python 环境已装 pandas/numpy，其余需 `pip install scikit-learn shap igraph leidenalg matplotlib joblib`。
