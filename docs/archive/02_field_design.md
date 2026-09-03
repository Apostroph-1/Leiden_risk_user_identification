# 风险用户识别模型 - 字段体系与口径

> 覆盖机票 + 酒店 + 门票 + 工单日志多业务线。
> 约束：线上只跑 SQL → 落离线表；线下用离线表 + python + mysql 建模；Tableau 接 mysql 可视化。

---

## 一、整体分层

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: ODS（线上库，只读）                                │
│  ods_callcenterdb_cc_compensation / flight.* / pp_pub.* /   │
│  hotel.* / ticket.*                                          │
└─────────────────────────────────────────────────────────────┘
                            ↓ 线上 SQL 抽取
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: DWD 离线明细表（线上产出，按日分区）                │
│  leiden.dwd_flight_order_di                                 │
│  leiden.dwd_hotel_order_di                                  │
│  leiden.dwd_ticket_order_di                                 │
│  leiden.dwd_callcenter_compensation_di                       │
│  leiden.dwd_pay_info_di                                     │
│  leiden.dwd_refund_di                                        │
└─────────────────────────────────────────────────────────────┘
                            ↓ 线下 SQL 聚合
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: DWS 用户-日宽表（mysql 或 spark 均可）             │
│  leiden.dws_user_biz_daily（按业务线拆分）                    │
│  leiden.dws_user_cross_biz_daily（跨业务线汇总）             │
└─────────────────────────────────────────────────────────────┘
                            ↓ Python 特征工程
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: 特征表（mysql）                                    │
│  leiden.feature_user_risk_profile                            │
└─────────────────────────────────────────────────────────────┘
                            ↓ Python 模型
┌─────────────────────────────────────────────────────────────┐
│  Layer 5: 模型输出（mysql）                                   │
│  leiden.model_user_risk_score                                │
└─────────────────────────────────────────────────────────────┘
                            ↓ Tableau 接 mysql
┌─────────────────────────────────────────────────────────────┐
│  Layer 6: 可视化                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、多业务线 DWD 字段设计

### 2.1 机票 DWD（`leiden.dwd_flight_order_di`）

| 字段 | 含义 | 口径 |
|---|---|---|
| dt | 日期分区 | |
| order_no | 订单号 | 国内取 main_order_no，国际取 order_no |
| user_id | 用户ID | 全局主键，flight 表自带 |
| username | 用户名 | qunar_username |
| status_code | 原始状态码 | int |
| status_name | 状态中文名 | CASE WHEN 映射 |
| pay_ok | 是否支付成功 | 0/1 |
| is_ticket_success | 是否出票成功 | 0/1 |
| is_apply_refund | 是否申请退款 | refund_apply_time 非空 |
| total_price | 订单总价 | |
| total_ticket_price | 票面总价 | |
| ip | 下单IP | |
| contact_mob | 联系人手机 | |
| dep_date | 出发日期 | |
| arr_time | 到达时间 | |
| cabin | 舱位 | |
| flight_num | 航班号 | |
| passenger_name | 乘机人姓名 | array，来自 passenger_info |
| passenger_card_num | 乘机人证件号 | array |
| passenger_mobile | 乘机人手机 | array |
| pay_tool_id | 支付工具标识 | cardnumf6l4join 或 thirdUid |
| pay_brand_name | 支付品牌 | |
| pay_time | 支付时间 | |
| refund_amount | 退款金额 | 来自 refund 表 |

### 2.2 酒店 DWD（`leiden.dwd_hotel_order_di`）

| 字段 | 含义 | 口径 |
|---|---|---|
| dt | 日期分区 | |
| order_no | 订单号 | |
| user_id | 用户ID | |
| status_name | 订单状态 | 预订成功/已入住/已离店/已取消/已退款 |
| pay_ok | 是否支付成功 | |
| total_price | 订单总价 | |
| room_nights | 入住晚数 | checkout_date - checkin_date |
| checkin_date | 入住日期 | |
| checkout_date | 离店日期 | |
| room_type | 房型 | |
| hotel_id | 酒店ID | |
| city_id | 城市ID | |
| ip | 下单IP | |
| contact_mob | 联系人手机 | |
| guest_name | 入住人姓名 | array |
| guest_card_num | 入住人证件号 | array |
| pay_tool_id | 支付工具标识 | |
| pay_time | 支付时间 | |
| refund_amount | 退款金额 | |
| is_apply_refund | 是否申请退款 | |
| first_night_price | 首晚价格 | 仅酒店业务线使用 |

### 2.3 门票 DWD（`leiden.dwd_ticket_order_di`）

| 字段 | 含义 | 口径 |
|---|---|---|
| dt | 日期分区 | |
| order_no | 订单号 | |
| user_id | 用户ID | |
| status_name | 订单状态 | 待使用/已使用/已取消/已退款 |
| pay_ok | 是否支付成功 | |
| total_price | 订单总价 | |
| ticket_id | 票品ID | |
| scenic_id | 景区ID | |
| visit_date | 游览日期 | |
| ticket_type | 票种 | |
| guest_name | 游客姓名 | array |
| guest_card_num | 游客证件号 | array |
| ip | 下单IP | |
| contact_mob | 联系人手机 | |
| pay_tool_id | 支付工具标识 | |
| pay_time | 支付时间 | |
| refund_amount | 退款金额 | |
| is_apply_refund | 是否申请退款 | |

### 2.4 客诉赔付 DWD（`leiden.dwd_callcenter_compensation_di`）

按 01_field_dictionary.md 修正后的口径：

| 字段 | 含义 | 口径 |
|---|---|---|
| dt | 日期分区 | |
| order_no | 订单号 | |
| biz_line | 业务线 | 机票/酒店/门票/… |
| user_id | 用户ID | MAX(user_id)，标量 |
| problem_name | 问题类型 | array_distinct |
| compensation_status | 赔付状态 | array_distinct |
| compensation_amount | 赔付金额 | SUM(pay_success) |
| refund_amount | 退款金额 | SUM(pay_success) |
| total_amount | 赔付总金额 | SUM(pay_success) |
| audit_result | 审核结果 | array_distinct |
| reject_back | 驳回原因 | array_distinct |
| responser | 责任人 | |
| detail_reason | 详细原因 | |
| first_create_time | 首次发起时间 | MIN(create_time) |
| last_update_time | 最后更新时间 | MAX(update_time) |
| auto_pay | 是否自动赔付 | |
| del_flag | 删除标记 | MAX(del) |

---

## 三、DWS 用户-日宽表设计

### 3.1 按业务线（`dws_user_biz_daily`）

| 字段 | 含义 |
|---|---|
| dt | 日期 |
| biz_line | 业务线 |
| user_id | 用户ID |
| dt_total_order_cnt | 当日订单数 |
| dt_pay_ok_order_cnt | 当日支付成功数 |
| dt_pay_ok_order_amount | 当日支付金额 |
| dt_ticket_success_order_cnt | 当日履约成功数 |
| dt_cancel_order_cnt | 当日取消数 |
| dt_refund_order_cnt | 当日退款数 |
| dt_refund_amount | 当日退款金额 |
| dt_gq_order_cnt | 当日改签数（仅机票） |
| dt_compensation_cnt | 当日客诉赔付笔数 |
| dt_compensation_amount | 当日赔付金额 |
| dt_distinct_pay_tool_cnt | 当日不同支付工具数 |
| dt_distinct_ip_cnt | 当日不同IP数 |
| dt_distinct_contact_mob_cnt | 当日不同联系人手机数 |
| dt_distinct_passenger_cnt | 当日不同乘机人/入住人/游客数 |
| dt_max_order_amount | 当日单笔最大金额 |

### 3.2 跨业务线汇总（`dws_user_cross_biz_daily`）

| 字段 | 含义 |
|---|---|
| dt | 日期 |
| user_id | 用户ID |
| dt_cross_order_cnt | 当日跨业务线订单总数 |
| dt_cross_biz_cnt | 当日涉及业务线数 |
| dt_cross_pay_ok_amount | 当日跨业务线支付总金额 |
| dt_cross_refund_amount | 当日跨业务线退款总金额 |
| dt_cross_compensation_amount | 当日跨业务线赔付总金额 |
| dt_cross_distinct_pay_tool_cnt | 当日跨业务线不同支付工具数 |
| dt_cross_distinct_ip_cnt | 当日跨业务线不同IP数 |
| dt_cross_distinct_mobile_cnt | 当日跨业务线不同手机号数 |

---

## 四、特征表（`feature_user_risk_profile`）

### 4.1 时间窗口

- 7d / 30d / 90d 滚动窗口
- snapshot 取 T-1

### 4.2 字段分组

#### A. 规模特征
- `order_cnt_7d/30d/90d`
- `pay_ok_amount_7d/30d/90d`
- `cross_biz_cnt_7d/30d/90d`（跨业务线数）

#### B. 风险率特征
- `refund_rate_7d/30d/90d` = 退款订单数 / 订单总数
- `refund_amount_rate_7d/30d/90d` = 退款金额 / 支付金额
- `cancel_rate_7d/30d/90d`
- `compensation_rate_7d/30d/90d` = 赔付订单数 / 订单总数
- `compensation_amount_rate_7d/30d/90d` = 赔付金额 / 支付金额

#### C. 身份聚集特征
- `distinct_pay_tool_cnt_7d/30d/90d`
- `distinct_ip_cnt_7d/30d/90d`
- `distinct_contact_mob_cnt_7d/30d/90d`
- `distinct_passenger_cnt_7d/30d/90d`
- `pay_tool_per_order_avg_30d`
- `ip_per_order_avg_30d`

#### D. 行为异常特征
- `min_interval_between_order_min_7d`（7日内两笔订单最短间隔，秒）
- `max_order_amount_30d`
- `night_order_cnt_30d`（0-6点下单数）
- `same_flight_diff_passenger_cnt_30d`（同航班不同乘机人，黄牛识别）
- `same_passenger_diff_user_cnt_30d`（同乘机人不同账号，代购识别）
- `cross_biz_burst_cnt_7d`（7日内跨业务线突增订单数）

#### E. 客诉特征
- `compensation_reject_cnt_30d`（30日驳回笔数）
- `compensation_auto_pay_rate_30d`（自动赔付占比）
- `distinct_problem_type_cnt_30d`（问题类型多样性）

#### F. 图网络连通特征（可选，进阶）
- `pay_tool_link_user_cnt_30d`（同支付工具关联账号数）
- `ip_link_user_cnt_30d`（同IP关联账号数）
- `mobile_link_user_cnt_30d`（同手机关联账号数）
- `connected_component_id`（连通分量ID）

---

## 五、标签定义（`label_user_risk`）

风险用户采用**复合标签**，分三级：

| 标签 | 定义 | 口径 |
|---|---|---|
| `is_refund_abuser` | 退款滥用 | 30d 退款率 ≥ 0.5 且 退款金额率 ≥ 0.3 |
| `is_compensation_abuser` | 赔付滥用 | 30d 赔付订单率 ≥ 0.3 且 赔付金额率 ≥ 0.2 |
| `is_cancel_abuser` | 恶意取消 | 30d 取消率 ≥ 0.5 且 取消数 ≥ 5 |
| `is_identity_fraud` | 身份聚集欺诈 | 30d 不同支付工具/IP/手机号 任一 ≥ 5 |
| `is_cross_biz_abuser` | 跨业务线薅羊毛 | 30d 跨业务线订单 ≥ 3 且 跨业务线赔付率 ≥ 0.3 |
| `is_risk_user` | 综合风险 | 上述任一命中 = 1 |

> 阈值为初版，建议先跑分布再定。回溯标注时取 T-30 ~ T-1 窗口计算标签，T 日特征对应 T+1 ~ T+30 标签（避免标签泄露）。

---

## 六、字段口径补充说明

### 6.1 refund_amount 双源问题
- flight_info 侧：来自 refund 表 `sum(amt)`
- comp 侧：来自 ods_callcenterdb `refund_amount`（仅 pay_success）
- **建模取 comp 侧**，因为 comp 反映的是"用户最终到手的赔付"，更贴近风险语义；flight 侧 refund 仅作交叉校验。

### 6.2 user_id 主键
- 全局统一用 `flight_info.user_id` / `hotel_info.user_id` / `ticket_info.user_id`（各业务线订单表自带），其余表通过 order_no 反查 user_id。
- comp.user_id、refund.user_id、pay_info.user_id **仅作校验**，不直接入模。

### 6.3 跨业务线 user_id 对齐
- 机票 user_id、酒店 user_id、门票 user_id 必须是同一套账号体系（Qunar 主账号）。
- 建表前需先和酒店/门票业务方确认 user_id 口径一致；如不一致，需用 gid 做桥接表 `dim_user_id_mapping`。

### 6.4 时间窗口对齐
- pay_info 从 2026-03-01 起准确 → 训练样本区 `dt >= '2026-03-01'`
- 回溯特征允许 2026-01-01 起，但样本只取 3-1 后
