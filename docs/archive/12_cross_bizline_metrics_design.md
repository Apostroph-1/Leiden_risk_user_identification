## 跨业务线指标体系设计方案

## 目标

当前多模型投票体系仅基于机票(FLIGHT)单业务线指标。本方案定义酒店(HOTEL)、门票(TICKET)、度假(TRAVEL)三条业务线按 device_id 聚合后的指标，并设计跨业务线交叉特征，接入现有 6 模型投票框架，识别多业务线交叉高风险设备。

## 一、设计原则

1. **字段命名一致性**：各业务线字段统一以 `hotel_`/`ticket_`/`travel_` 前缀，与现有 `flight_` 对齐
2. **指标分层一致性**：每条业务线产出三类字段 — 原始聚合量、派生比率、行为标记(0/1)
3. **按 device_id 聚合**：所有业务线均以 device_id 为主键，与现有机票宽表对齐后左连接
4. **缺失值处理**：某业务线无订单的设备，其字段填 0（量类）或 NaN（比率类），与现有逻辑一致

## 二、各业务线指标定义

### 2.1 HOTEL（酒店）

#### 原始聚合字段

| 字段名 | 类型 | 说明 |
|--------|------|------|
| hotel_total_order_cnt | int | 酒店总订单量 |
| hotel_pay_ok_order_cnt | int | 支付成功订单量 |
| hotel_pay_ok_order_amount | float | 支付成功总金额 |
| hotel_refund_order_cnt | int | 退款单量 |
| hotel_refund_amount | float | 退款总金额（负值） |
| hotel_cancel_order_cnt | int | 取消单量 |
| hotel_checkin_success_cnt | int | 入住成功单量 |
| hotel_voucher_sum | float | 总代金券金额 |
| hotel_voucher_order_cnt | int | 总用券数量 |
| hotel_service_fee_sum | float | 总服务费 |
| hotel_scalper_cnt | int | 总黄牛单量 |
| hotel_intercept_cnt | int | 总拦截单量 |
| hotel_new_cnt | int | 总新客单量 |
| hotel_fenxiao_cnt | int | 总分销单量 |
| hotel_pre_day_avg | float | 平均提前预订天数 |
| hotel_combine_order_cnt | int | 总合单的订单数 |
| hotel_night_order_cnt | int | 凌晨0-6点下单总数 |
| hotel_weekend_order_cnt | int | 周末订单总数 |
| hotel_distinct_checkin_city_cnt | int | 去重入住城市数 |
| hotel_distinct_hotel_cnt | int | 去重酒店数 |
| hotel_distinct_room_type_cnt | int | 去重房型数 |
| hotel_avg_room_price | float | 平均房单价 |
| hotel_min_refund_pay_interval_sec | int | 最小退款-支付间隔(秒) |
| hotel_max_refund_pay_interval_sec | int | 最大退款-支付间隔(秒) |
| hotel_avg_refund_pay_interval_sec | int | 平均退款-支付间隔(秒) |
| hotel_cardinality_refund_pay_time_diff | int | 去重退款时间差个数 |
| hotel_comp_total_amount | float | 总赔付金额 |

#### 聚集类字段（与机票对齐）

| 字段名 | 说明 |
|--------|------|
| hotel_distinct_user_id_cnt | 去重userId数 |
| hotel_distinct_username_cnt | 去重username数 |
| hotel_distinct_mobile_cnt | 去重联系人电话数 |
| hotel_distinct_email_cnt | 去重email数 |
| hotel_distinct_pay_tool_cnt | 去重支付工具数 |
| hotel_distinct_ip_cnt | 去重IP数 |
| hotel_distinct_guest_name_cnt | 去重入住人姓名数 |
| hotel_distinct_guest_mobile_cnt | 去重入住人电话数 |

注：酒店不需要提供身份证信息，因此无入住人证件字段。入住人身份聚集改用“姓名+电话”双维度。

#### 派生比率（在 derive_features 中计算）

| 字段名 | 公式 |
|--------|------|
| hotel_refund_rate | hotel_refund_order_cnt / hotel_total_order_cnt |
| hotel_refund_amount_rate | hotel_refund_amount / hotel_pay_ok_order_amount |
| hotel_comp_amount_rate | hotel_comp_total_amount / hotel_pay_ok_order_amount |
| hotel_cancel_rate | hotel_cancel_order_cnt / hotel_total_order_cnt |
| hotel_voucher_order_rate | hotel_voucher_order_cnt / hotel_total_order_cnt |
| hotel_scalper_rate | hotel_scalper_cnt / hotel_total_order_cnt |
| hotel_intercept_rate | hotel_intercept_cnt / hotel_total_order_cnt |
| hotel_avg_order_amount | hotel_pay_ok_order_amount / hotel_pay_ok_order_cnt |
| hotel_user_per_order | hotel_distinct_user_id_cnt / hotel_total_order_cnt |
| hotel_guest_name_per_order | hotel_distinct_guest_name_cnt / hotel_total_order_cnt |
| hotel_guest_mobile_per_order | hotel_distinct_guest_mobile_cnt / hotel_total_order_cnt |

#### 行为标记（0/1，参与 rule_hit_cnt）

| 字段名 | 判定逻辑 | 含义 |
|--------|----------|------|
| hotel_is_short_refund | hotel_min_refund_pay_interval_sec <= 3600 | 支付后1小时内退款 |
| hotel_is_machine_refund | hotel_cardinality_refund_pay_time_diff == 1 AND hotel_refund_order_cnt >= 5 | 机器批量退款 |
| hotel_is_night_heavy | hotel_night_order_cnt / hotel_total_order_cnt >= 0.3 | 凌晨下单占比>=30% |
| hotel_is_multi_account | hotel_distinct_user_id_cnt >= 2 | 多账号 |
| hotel_is_multi_pay_tool | hotel_distinct_pay_tool_cnt >= 3 | 多支付工具 |
| hotel_is_multi_guest_mobile | hotel_distinct_guest_mobile_cnt >= 5 | 多入住人电话 |
| hotel_is_multi_guest_name | hotel_distinct_guest_name_cnt >= 5 | 多入住人姓名 |

### 2.2 TICKET（门票/景区）

与 HOTEL 完全对称，差异仅在业务特有字段：

- `hotel_distinct_checkin_city_cnt` -> `ticket_distinct_venue_city_cnt`（去重景区城市数）
- `hotel_distinct_hotel_cnt` -> `ticket_distinct_venue_cnt`（去重景区/场馆数）
- `hotel_distinct_room_type_cnt` -> `ticket_distinct_ticket_type_cnt`（去重票种数）
- `hotel_avg_room_price` -> `ticket_avg_ticket_price`（平均票单价）
- `hotel_distinct_guest_id_cnt` -> `ticket_distinct_visitor_id_cnt`（去重游玩人证件数）
- `hotel_is_multi_guest_mobile` -> `ticket_is_multi_visitor`（多游玩人证件>=5）

### 2.3 TRAVEL（度假/旅游）

与 HOTEL 完全对称，差异仅在业务特有字段：

- `hotel_distinct_checkin_city_cnt` -> `travel_distinct_dest_city_cnt`（去重目的地城市数）
- `hotel_distinct_hotel_cnt` -> `travel_distinct_product_type_cnt`（去重产品类型数）
- `hotel_distinct_room_type_cnt` -> `travel_distinct_duration_cnt`（去重行程天数种类数）
- `hotel_avg_room_price` -> `travel_avg_package_price`（平均套餐单价）
- `hotel_distinct_guest_id_cnt` -> `travel_distinct_traveler_id_cnt`（去重出行人证件数）
- `hotel_is_multi_guest_mobile` -> `travel_is_multi_traveler`（多出行人证件>=5）

## 三、跨业务线交叉特征

以上是各业务线独立指标。以下是跨业务线派生的交叉特征，用于检测多业务线交叉高风险。

### 3.1 全业务线汇总

| 字段名 | 公式 | 含义 |
|--------|------|------|
| all_total_order_cnt | 四线 total_order_cnt 之和 | 全业务线总订单量 |
| all_pay_ok_amount | 四线 pay_ok_order_amount 之和 | 全业务线支付总金额 |
| all_refund_order_cnt | 四线 refund_order_cnt 之和 | 全业务线退款单量 |
| all_refund_amount | 四线 refund_amount 之和 | 全业务线退款总金额 |
| all_comp_amount | 四线 comp_total_amount 之和 | 全业务线赔付总金额 |
| all_refund_rate | all_refund_order_cnt / all_total_order_cnt | 全业务线退款率(单量口径) |
| all_refund_amount_rate | all_refund_amount / all_pay_ok_amount | 全业务线退款率(金额口径) |
| all_comp_rate | all_comp_amount / all_pay_ok_amount | 全业务线赔付率 |
| bizline_cnt | 四线中 total_order_cnt > 0 的条数(1-4) | 活跃业务线数 |

### 3.2 跨业务线身份重叠

检测团伙跨业务线作案的关键。同一 device_id 在不同业务线中使用的 userId、手机号、支付工具、IP 是否重叠，直接反映是否同一批身份在多线操作。

| 字段名 | 公式 | 含义 |
|--------|------|------|
| cross_user_id_overlap | 四线 user_id 列表交集大小 | 跨线重叠userId数 |
| cross_mobile_overlap | 四线手机号列表交集大小 | 同一手机号在多线使用 |
| cross_pay_tool_overlap | 四线支付工具列表交集大小 | 同一支付工具在多线使用 |
| cross_ip_overlap | 四线IP列表交集大小 | 同一IP在多线下单 |
| cross_identity_overlap_total | 上述四个 overlap 之和 | 跨线身份重叠总数 |

注：计算 overlap 需要在聚合阶段保留各业务线的 user_id/mobile/pay_tool/ip 列表明细（JSON string 格式），然后在 Python 中做集合交集。

### 3.3 跨业务线风险标记

| 字段名 | 判定逻辑 | 含义 |
|--------|----------|------|
| cross_is_multi_bizline | bizline_cnt >= 2 | 同一设备活跃在2个以上业务线 |
| cross_is_all_refund_heavy | 四线各自的 refund_rate 均 >= 0.3 | 每条线都在大量退款 |
| cross_is_multi_account_all | 四线各自的 distinct_user_id_cnt 均 >= 2 | 每条线都多账号 |
| cross_is_comp_multi_line | 至少2条线 comp_total_amount > 0 | 多线均有赔付 |
| cross_is_identity_overlap | cross_identity_overlap_total >= 1 | 跨线身份重叠 |
| cross_bizline_risk_cnt | 上述5个标记之和(0-5) | 跨线风险命中数 |

## 四、接入现有 6 模型投票框架

### 4.1 特征列表扩展

现有 FEATURE_COLS 有 54 个机票特征。扩展后约 180 个特征：

```
FEATURE_COLS = [
    # 机票 54 (现有)
    flight_total_order_cnt, ..., flight_comp_total_amount,
    # 酒店 ~35 (原始 + 派生比率)
    hotel_total_order_cnt, ..., hotel_comp_total_amount,
    # 门票 ~35 (同构)
    ticket_total_order_cnt, ..., ticket_comp_total_amount,
    # 度假 ~35 (同构)
    travel_total_order_cnt, ..., travel_comp_total_amount,
    # 跨业务线交叉 ~15
    all_total_order_cnt, all_pay_ok_amount, all_refund_order_cnt,
    all_refund_amount, all_comp_amount, all_refund_rate,
    all_refund_amount_rate, all_comp_rate, bizline_cnt,
    cross_user_id_overlap, cross_mobile_overlap, cross_pay_tool_overlap,
    cross_ip_overlap, cross_identity_overlap_total, cross_bizline_risk_cnt,
    # 各线行为标记 6x3=18
    hotel_is_*, ticket_is_*, travel_is_*,
]
```

### 4.2 伪标签规则扩展

现有伪标签仅基于机票。扩展后加入跨业务线条件：

```python
strong = (
    # 现有机票规则 (不变)
    (df["refund_rate"] >= 0.5) & (df["flight_refund_order_cnt"] >= 5)
    | (df["flight_comp_total_amount"] >= 500) & (df["flight_distinct_user_id_cnt"] >= 2)
    | (df["flight_scalper_cnt"] >= 1)
    | (df["is_machine_refund"] == 1)
    | (df["flight_distinct_user_id_cnt"] >= 8) & (df["flight_total_order_cnt"] >= 20)
    | (df["flight_intercept_cnt"] >= 3)
    # 新增跨业务线规则
    | (df["cross_bizline_risk_cnt"] >= 3)
    | (df["all_comp_amount"] >= 1000) & (df["bizline_cnt"] >= 2)
    | (df["cross_identity_overlap_total"] >= 2)
    | (df["all_refund_rate"] >= 0.5) & (df["all_total_order_cnt"] >= 20)
)

normal = (
    # 现有 (不变)
    (df["flight_refund_order_cnt"] == 0) & (df["flight_comp_total_amount"] == 0)
    & (df["flight_distinct_user_id_cnt"] == 1) & (df["flight_scalper_cnt"] == 0)
    & (df["flight_intercept_cnt"] == 0) & (df["flight_distinct_pay_tool_cnt"] <= 2)
    & (df["flight_uid_distinct_card_num_cnt"] <= 2)
    # 新增跨线条件
    & (df["all_comp_amount"] == 0)
    & (df["bizline_cnt"] <= 1)
    & (df["cross_identity_overlap_total"] == 0)
)
```

### 4.3 rule_hit_cnt 扩展

现有 6 条规则标记，新增各线 + 跨线后变为约 30 条：

```python
rule_cols = [
    # 机票 6 条（现有）
    "is_short_refund", "is_machine_refund", "is_night_heavy",
    "is_multi_account", "is_multi_pay_tool", "is_multi_passenger",
    # 酒店 6 条
    "hotel_is_short_refund", "hotel_is_machine_refund", "hotel_is_night_heavy",
    "hotel_is_multi_account", "hotel_is_multi_pay_tool", "hotel_is_multi_guest_mobile",
    "hotel_is_multi_guest_name",
    # 门票 6 条
    "ticket_is_short_refund", "ticket_is_machine_refund", "ticket_is_night_heavy",
    "ticket_is_multi_account", "ticket_is_multi_pay_tool", "ticket_is_multi_visitor",
    # 度假 6 条
    "travel_is_short_refund", "travel_is_machine_refund", "travel_is_night_heavy",
    "travel_is_multi_account", "travel_is_multi_pay_tool", "travel_is_multi_traveler",
    # 跨线 5 条 (0/1)
    "cross_is_multi_bizline", "cross_is_all_refund_heavy",
    "cross_is_multi_account_all", "cross_is_comp_multi_line",
    "cross_is_identity_overlap",
]
```

rule_hit_cnt 上限从 6 扩展到 29。

### 4.4 分层阈值调整

现有分层用固定阈值。跨线扩展后规则条数翻 5 倍，阈值需重新调参：

```python
# [TUNABLE] 阈值需根据新数据分布重新调整
if vote >= total * 0.6 and rule_hits >= 4:     # 原: >=2, 现: 29条中>=4
    return "高风险"
if vote >= total * 0.4 and rule_hits >= 2:     # 原: vote>=2 and rule>=1
    return "中风险"
if vote >= 1 or rule_hits >= 1:
    return "疑似风险"
return "普通用户"
```

### 4.5 投票架构不变

6 个模型（3 无监督 + 3 监督）的架构不变。变化的是：
- 输入特征从 54 维扩展到约 180 维
- 伪标签规则增加跨线条件
- rule_hit_cnt 从 6 条扩展到 29 条
- 无监督模型自动在 180 维空间中发现跨线异常模式
- 监督模型学到跨线规则

## 五、数据准备要求

需要数据团队按以下口径产出三张宽表（与现有机票宽表同构）：

1. `hotel_feature_detail_90days.csv` - 按 device_id 聚合，字段见 2.1
2. `ticket_feature_detail_90days.csv` - 按 device_id 聚合，字段见 2.2
3. `travel_feature_detail_90days.csv` - 按 device_id 聚合，字段见 2.3

聚合口径与机票一致：T-90d，device_id 为主键，仅保留各业务线 total_order_cnt > 5 的设备。

各业务线宽表中需保留以下明细字段（JSON string 格式），供跨线身份交集计算：
- `*_distinct_user_id` - 去重 userId 列表，形如 ["A","B"]
- `*_distinct_mobile` - 去重手机号列表
- `*_distinct_pay_tool` - 去重支付工具列表
- `*_distinct_ip` - 去重 IP 列表

## 六、实施步骤

1. 数据团队按本方案产出 hotel/ticket/travel 三张宽表
2. 在 notebook 08 的 Cell 1（数据加载）中增加三个 CSV 读取和左连接
3. 在 Cell 2（特征派生）中增加各业务线派生比率和行为标记
4. 在 Cell 3（特征列表）中扩展 FEATURE_COLS
5. 在 Cell 4（伪标签）中增加跨线规则
6. Cell 5-6（模型训练）无需改动，自动适应新特征维度
7. Cell 7（投票）中扩展 rule_cols 列表
8. Cell 8（分层）中调整阈值
9. 重新训练，对比单业务线 vs 跨业务线的风险分层差异

## 七、交叉高风险判断逻辑

最终核心问题：一个设备在机票线被判高风险，同时在酒店/门票/度假线也被判高风险的概率有多大？

产出一张交叉表：

| | 机票高风险 | 机票非高风险 |
|---|---|---|
| 多线+高风险 | A（交叉高危） | B |
| 多线+非高风险 | C | D |

- A 类设备（多线同时高危）是最高优先级打击对象
- cross_bizline_risk_cnt >= 3 的设备直接进入高危池
- 单线高危但跨线无交叉的，降一级处理

在 final_merged_output 中新增列 cross_bizline_risk_cnt 和 cross_risk_flag，供前端展示和后续 Leiden 社团关联使用。
