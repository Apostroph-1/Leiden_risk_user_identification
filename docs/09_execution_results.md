# 执行结果报告（2026-08-20 全量跑通）

> 数据：865,389 个设备（T-90d 聚合，机票总订单 >5 单）
> 全量执行风险分类管线 + Leiden 团伙识别，产出在 `data/model_output/`

---

## 一、风险分类管线（08_multi_model_stratify.py）

### 1.1 伪标签分布

| 伪标签 | 数量 | 占比 |
|---|---|---|
| 异常 (1) | 411,844 | 47.6% |
| 正常 (0) | 142,794 | 16.5% |
| 未标记 (-1) | 310,751 | 35.9% |

> 伪标签由强规则生成，仅供监督模型训练；未标记样本不参与训练。

### 1.2 六模型异常检测数

| 模型 | 异常数 | 说明 |
|---|---|---|
| Isolation Forest | 86,539 | 全局异常，contamination=0.1 |
| One-Class SVM | 85,688 | RBF 核，nu=0.1，20K 采样训练 |
| LOF | 25,808 | 局部密度异常，30K 采样训练 |
| XGBoost | 669,403 | 伪标签监督，AP=1.0 |
| LightGBM | 626,549 | 伪标签监督，AP=1.0 |
| RandomForest | 720,110 | 伪标签监督，AP=1.0 |

> 监督模型 AP=1.0 是预期结果——伪标签由规则生成，模型在同一特征集上可完美复现。

### 1.3 模型相关性矩阵

|  | iForest | OC-SVM | LOF | XGB | LGB | RF |
|---|---|---|---|---|---|---|
| iForest | 1.00 | 0.63 | 0.28 | 0.15 | 0.14 | 0.13 |
| OC-SVM | 0.63 | 1.00 | 0.37 | 0.07 | 0.05 | 0.06 |
| LOF | 0.28 | 0.37 | 1.00 | 0.00 | -0.01 | 0.01 |
| XGB | 0.15 | 0.07 | 0.00 | 1.00 | 0.86 | 0.83 |
| LGB | 0.14 | 0.05 | -0.01 | 0.86 | 1.00 | 0.73 |
| RF | 0.13 | 0.06 | 0.01 | 0.83 | 0.73 | 1.00 |

关键发现：
- 无监督三模型间相关性低（0.28-0.63），互补性强
- 监督三模型间高度相关（0.73-0.86），共识强
- 无监督与监督间几乎不相关（0.003-0.15），抓不同类型异常——多模型投票的价值

### 1.4 投票分布

| 投票数（6 模型中判定异常的个数） | 设备数 |
|---|---|
| 0 | 134,661 |
| 1 | 52,187 |
| 2 | 43,726 |
| 3 | 531,589 |
| 4 | 48,237 |
| 5 | 43,191 |
| 6 | 11,798 |

### 1.5 四级风险分层结果

| 风险级别 | 设备数 | 占比 | 条件 |
|---|---|---|---|
| 高风险 | 27,232 | 3.1% | vote >= 60% AND rule_hit >= 2 |
| 中风险 | 218,967 | 25.3% | vote >= 2 AND rule_hit >= 1 |
| 疑似风险 | 512,056 | 59.2% | vote >= 1 OR rule_hit >= 1 |
| 普通用户 | 107,134 | 12.4% | 其余 |

### 1.6 SHAP 全局特征重要性（Top 10）

| 排名 | 特征 | SHAP 均值绝对值 | 含义 |
|---|---|---|---|
| 1 | intercept_rate | 8.424 | 拦截率（被风控拦截的订单比例） |
| 2 | flight_uid_distinct_card_num_cnt | 1.719 | 去重乘机人证件数 |
| 3 | refund_rate | 1.281 | 退款率 |
| 4 | passenger_per_order | 0.217 | 单均乘机人数 |
| 5 | flight_cardinality_refund_pay_time_diff | 0.216 | 退款-支付时间差多样性 |
| 6 | refund_amount_rate | 0.191 | 退款金额率 |
| 7 | flight_distinct_user_id_cnt | 0.157 | 去重账号数 |
| 8 | flight_uid_distinct_passenger_mobile_cnt | 0.138 | 去重乘机人手机数 |
| 9 | flight_pay_tool_size | 0.134 | 支付工具数 |
| 10 | flight_pay_ok_order_cnt | 0.126 | 支付成功订单量 |

### 1.7 决策树 surrogate 规则（准确率 98.6%）

```
IF intercept_rate > 0 THEN 异常
IF intercept_rate = 0 AND refund_rate > 0 AND uid_distinct_card_num > 2.5 THEN 异常
IF intercept_rate = 0 AND refund_rate = 0 AND is_multi_account = 1 THEN 异常
IF intercept_rate = 0 AND refund_rate = 0 AND uid_distinct_card_num <= 7.5 AND NOT multi_account THEN 正常
```

业务解读：拦截率是最强信号——被风控拦截过的设备直接判异常；其次是退款+多乘机人证件（代购退款滥用）；再次是多账号聚集。

---

## 二、Leiden 团伙识别（07_leiden_community.py）

### 2.1 构图参数

| 参数 | 值 |
|---|---|
| 构图范围 | 仅高风险设备（27,199 个） |
| 实际匹配设备 | 30,301 行 |
| 关联维度 | user_id / pay_tool / 乘机人证件 / 乘机人手机 |
| 边权 | 共现次数 |
| 最小团伙规模 | 3 |

### 2.2 图规模

| 指标 | 值 |
|---|---|
| 总边数 | 424,875 |
| 总节点数 | 440,784 |
| 社区数 | 23,561 |
| 满足最小规模的团伙 | 23,559 |
| 高危团伙 | 23,559（全部，因构图设备均为高风险） |
| 最大团伙规模 | 10,661 |

### 2.3 团伙规模分布

| 统计量 | 值 |
|---|---|
| 均值 | 18.7 |
| 中位数 | 12 |
| 75 分位 | 17 |
| 最大 | 10,661 |
| 规模 >= 10 的团伙 | 17,768 |

### 2.4 Top 5 团伙

| 团伙 ID | 规模 | 设备数 | 账号数 | 乘机人证件数 | 手机数 |
|---|---|---|---|---|---|
| 0 | 10,661 | 963 | 2,503 | 4,135 | 2,135 |
| 1 | 5,612 | 132 | 1,955 | 1,938 | 1,378 |
| 2 | 4,641 | 221 | 1,302 | 2,163 | 299 |
| 3 | 4,556 | 156 | 981 | 2,680 | 492 |
| 4 | 3,878 | 135 | 625 | 2,681 | 139 |

> 团伙 0 是最大疑似团伙：963 个高风险设备共享 2,503 个账号和 4,135 个乘机人证件，高度疑似有组织薅羊毛/代购团伙。

---

## 三、产出文件清单

| 文件 | 大小 | 说明 |
|---|---|---|
| device_risk_score.csv | 166 MB | 865K 设备风险分层主表 |
| graph_edges.csv | 23 MB | 图边表（可导入 Neo4j/Gephi） |
| device_community.csv | 13 MB | 节点级社区归属 |
| gang_list.csv | 0.6 MB | 团伙列表 |
| shap_global_importance.csv | - | SHAP 全局特征重要性 |
| shap_summary.png | - | SHAP summary 图 |
| shap_top10_anomaly.csv | - | Top10 高风险设备 SHAP 局部解释 |
| tree_rules.txt / .png | - | 决策树 surrogate 规则 |
| model_correlation.png / .csv | - | 6 模型相关性热力图 |
| risk_level_distribution.png | - | 4 级分布柱状图 |
| xgb.pkl / lgb.pkl / rf.pkl | - | 训练好的模型 |
| tree_surrogate.pkl | - | 决策树 surrogate 模型 |
| model_comparison.txt | - | 模型对比报告 |

---

## 四、脚本修复记录

执行过程中发现并修复了 2 个 bug：

1. **08_multi_model_stratify.py 第 355 行**：`features=DF := df[...]` 赋值表达式语法错误 → 改为 `features=df[...]`
2. **08_multi_model_stratify.py 第 348-350 行**：SHAP 局部解释的 top_idx 从全量 df 取，但 sv 只算了前 3000 行 → 改为从 `df.iloc[:sample_n]` 子集取
3. **07_leiden_community.py build_edges**：`df.iterrows()` 遍历 865K 行极慢 → 改为 `explode()` 向量化
4. **07_leiden_community.py risk_devices**：取了 device_risk_score.csv 全部设备 → 改为只取 `risk_level == 高风险` 的设备
5. **07_leiden_community.py 第 97 行**：缩进错误（9 空格 → 8 空格）

---

## 五、后续建议

1. **人工抽检**：对 Top 20 团伙做人工核查，确认是否真为团伙薅羊毛
2. **阈值调优**：高风险占比 3.1% 可根据业务反馈调整投票阈值
3. **扩展构图**：后续接入酒店/门票数据后，跨业务线构图可发现跨线团伙
4. **IP 维度**：当前 IP 仅有计数无明细，需回原始订单表取 IP 明细加入构图
5. **Gephi 可视化**：graph_edges.csv 可直接导入 Gephi 做团伙可视化
6. **伪标签优化**：监督模型 AP=1.0 说明伪标签过于简单，后续可用 iForest 异常分做软标签替代硬规则
7. **风险分上线**：device_risk_score.csv 可导 MySQL 供 Tableau 展示
