# 字段字典与口径修正

> 基于 user_query 中提供的 SQL，逐表梳理字段口径，标注**需修正项**与**原因**。
> 修正项以 `❌→✅` 标注，后续所有离线表与模型以此为准。

---

## 一、源表清单

| 别名 | 源表 | 业务含义 | 粒度 |
|---|---|---|---|
| comp | `default.ods_callcenterdb_cc_compensation` | 客诉赔付工单 | 一笔赔付流水（一个 order_no 可有多笔） |
| pay_info | `pp_pub.dwd_fin_sub_trade_payment_account_detail_di` | 支付明细 | 一笔子交易 |
| passenger_info | `flight.dwd_ord_wide_order_ticket_di` | 乘机人信息 | 一张票 |
| flight_info | `flight.dwd_ord_wide_order_di` | 机票订单主表 | 一个订单 |
| refund | `pp_pub.dwd__qunar_selfpayord_di` | 自支付退款流水 | 一笔退款操作 |
| base | (子查询) | 用户-日聚合 | user_id × dt |

---

## 二、comp 表字段口径

### 2.1 字段字典

| 字段 | 类型 | 含义 | 口径说明 |
|---|---|---|---|
| order_no1 | string | 订单号 | = order_no，用于关联订单表 |
| problem_name | array<string> | 问题类型名称 | 同一订单多次赔付可能涉及不同问题类型，去重聚合 |
| compensation_amount | decimal | 赔付金额 | **仅 pay_success 状态** 的赔付金额 |
| consume_amount | decimal | 消费补偿金额 | 同上口径 |
| refund_amount | decimal | 退款金额 | 同上口径 |
| other_amount | decimal | 其他金额 | 同上口径 |
| total_amount | decimal | 赔付总金额 | 同上口径 |
| flow_no | array<string> | 流水号 | |
| create_id / create_time | array | 创建人/时间 | |
| update_id / update_time | array | 更新人/时间 | |
| problem_id | array<string> | 问题类型ID | |
| solution | array<string> | 解决方案 | |
| responser / responser_secondary | array<string> | 一/二责任人 | |
| detail_reason | array<string> | 详细原因 | |
| biz_type | array<string> | 业务类型 | |
| compensation_status | array<string> | 赔付状态 | 一个订单可有多个状态 |
| audit_result | array<string> | 审核结果 | |
| reject_back | array<string> | 驳回原因 | |
| compensation_way | array<string> | 赔付方式 | |
| user_id | array<string> | 用户ID | |
| user_name / user_mobile / user_email / nick_name | array | 用户信息 | |
| first_night_price | array<decimal> | 首晚价格 | 机票表里出现该字段命名异常，疑为脏字段 |
| room_number | array<string> | 房间号 | 同上，疑为脏字段 |
| compensation_solution_id | array<string> | 赔付方案ID | |
| auto_pay | array<string> | 是否自动赔付 | |
| show_helper | array<string> | 是否展示帮手 | |
| source | array<string> | 来源 | |
| biz_line | array<string> | 业务线 | |

### 2.2 口径修正项

#### ❌ 修正 1：`refund_aount` 拼写错误
- 原字段：`refund_aount`
- 修正：`refund_amount`
- 原因：拼写错误，"amount" 漏了 "m"，下游引用会出错。

#### ❌ 修正 2：金额聚合 IF(AVG≠MAX, SUM, AVG) 逻辑冗余
- 原逻辑：比较 pay_success 订单金额的 AVG 和 MAX，不等则 SUM，相等则取 AVG。
- 修正：直接 `SUM(CASE WHEN compensation_status='pay_success' THEN amount ELSE 0 END)`。
- 原因：单条 pay_success 记录时 SUM 即等于该值，IF 判断无意义，徒增计算量和可读性负担。`AVG(...)` 会在全部为 NULL 时返回 NULL，反而可能误判。

#### ❌ 修正 3：`user_id` 使用 array_agg 不合理
- 原逻辑：`array_distinct(array_agg(user_id))`，下游关联时取 `C.user_id[1]`。
- 修正：`MAX(user_id) AS user_id`（一个订单归属一个用户，取任一非空值即可）。
- 原因：同一 order_no 的赔付记录应属于同一 user_id；若出现多值说明源表 order_no 与 user_id 映射不一致，应排查源表而非用数组承载。

#### ❌ 修正 4：`del` 字段 array_agg 不合理
- 原逻辑：`array_distinct(array_agg(del))`。
- 修正：`MAX(del) AS del_flag`。
- 原因：del 是删除标记（0/1），取 MAX 即可判断是否被删除，无需数组。

#### ❌ 修正 5：`create_time`/`update_time` 用 array_agg 导致膨胀
- 原逻辑：array_agg 时间戳。
- 修正：`MIN(create_time) AS first_create_time, MAX(update_time) AS last_update_time`。
- 原因：时间戳去重聚合无业务意义，且数组膨胀严重；取首末时间即可覆盖"赔付首次发起"与"最后更新"两个口径。

#### ❌ 修正 6：`first_night_price` / `room_number` 疑为脏字段
- 原逻辑：从客诉表聚合酒店相关字段。
- 修正：机票业务线不使用；若确认源表为多业务线共用，则按 `biz_line` 过滤后再聚合。
- 原因：机票订单无"首晚价格""房间号"，字段出现说明源表混入了酒店客诉，需在 comp 表 WHERE 中加 `biz_line` 过滤或在模型层拆分。

---

## 三、pay_info 表字段口径

### 3.1 字段字典

| 字段 | 类型 | 含义 | 口径说明 |
|---|---|---|---|
| dt | string | 日期分区 | |
| orderid | string | 订单ID | |
| sub_out_trade_no | string | 子交易号 | |
| trade_time | datetime | 交易时间 | |
| pay_time | datetime | 支付时间 | |
| user_id | string | 用户ID | = ext_uid，q侧userId |
| pay_json | string | 支付报文JSON | |
| pay_brand_id / pay_brand_name | string | 支付品牌 | |
| sub_pay_amount | decimal | 子支付金额 | |
| order_type / order_type_name / order_type_name_new | string | 订单类型 | |
| pay_info | string | 支付工具标识 | = cardnumf6l4join 或 thirdUid |

### 3.2 口径修正项

#### ❌ 修正 7：`pay_info` 字段命名歧义
- 原字段：`pay_info`（与 CTE 表名、pay_json 都易混淆）。
- 修正：`pay_tool_id`。
- 原因：字段实际含义是"支付工具唯一标识"（卡号后6前4 或 第三方支付UID），命名为 `pay_tool_id` 更清晰，便于跨业务线复用。

#### ❌ 修正 8：`order_type_name_new = '机票'` 硬编码
- 原逻辑：WHERE 硬编码机票。
- 修正：去掉业务线过滤，改为字段保留 `biz_line`，在模型层按业务线拆分。
- 原因：多业务线建模需要复用同一支付明细表。

---

## 四、passenger_info 表字段口径

### 4.1 字段字典

| 字段 | 类型 | 含义 |
|---|---|---|
| order_no | string | 订单号（国内取 main_order_no，国际取 order_no） |
| uid | string | 用户UID |
| gid | string | 用户GID |
| username | string | Qunar用户名 |
| guest_name | array<string> | 乘机人姓名 |
| guest_card_num | array<string> | 乘机人证件号 |
| guest_mobile | array<string> | 乘机人手机 |
| guest_contact_mob | array<string> | 订单联系人手机（来自 o_contact_mob） |
| guest_ip | array<string> | 订单IP（来自 o_ip） |
| status | array<string> | 订单状态 |

### 4.2 口径修正项

#### ❌ 修正 9：`guest_contact_mob` / `guest_ip` 命名误导
- 原字段：`guest_contact_mob`、`guest_ip`。
- 修正：`order_contact_mob`、`order_ip`。
- 原因：这两个字段来自订单维度（o_contact_mob / o_ip），是下单人信息，不是乘机人信息。命名带 `guest_` 前缀会与 `guest_mobile`（真正的乘机人手机）混淆，导致风险模型误用。

---

## 五、flight_info 表字段口径

### 5.1 字段字典

| 字段 | 类型 | 含义 |
|---|---|---|
| dt | string | 日期分区 |
| order_no | string | 订单号 |
| user_id | string | 用户ID |
| qunar_username | string | 用户名 |
| status | string | 订单状态（CASE WHEN映射后） |
| pay_ok | int | 是否支付成功 |
| is_ticket_success | int | 是否出票成功 |
| is_apply_refund | int | 是否申请退款（refund_apply_time 非空） |
| total_price | decimal | 订单总价 |
| total_ticket_price | decimal | 票面总价 |
| ip | string | 下单IP |
| contact_mob | string | 联系人手机 |
| dep_date | string | 出发日期 |
| arr_time | string | 到达时间 |
| cabin | string | 舱位 |
| flight_num | string | 航班号 |
| uid | string | 用户UID |

### 5.2 口径修正项

#### ❌ 修正 10：status 映射 39 和 95 重复为"退款完成"
- 原逻辑：`when 39 then '退款完成'`、`when 95 then '退款完成'`。
- 修正：`when 39 then '退款完成'`、`when 95 then '退款完成(自动)'`，或保留原始 status 码作为 `status_code` 字段。
- 原因：两个状态码业务语义可能不同（如人工退款 vs 自动退款），合并后无法区分，对风险模型判别力有损失。

#### ❌ 修正 11：`uid` 与 `user_id` 同时存在未明确关系
- 原逻辑：两个字段都保留。
- 修正：统一用 `user_id`（字符串），`uid` 若为数值型则 `CAST(uid AS STRING) AS uid_str` 仅作排查用。
- 原因：下游关联口径必须统一，否则跨表 join 会漏数据。

---

## 六、refund 表字段口径

### 6.1 字段字典

| 字段 | 类型 | 含义 |
|---|---|---|
| dt | string | 日期（d） |
| orderid | string | 订单ID |
| busi_order_no | array<string> | 业务订单号（split后） |
| user_id | string | 用户ID（extdata['user_id']） |
| refund_amount | decimal | 退款金额（sum） |

### 6.2 口径修正项

#### ❌ 修正 12：`busi_order_no` split 后进入 group by 导致行数膨胀
- 原逻辑：`split(extdata['busi_order_no'],',') as busi_order_no`，并参与 `group by 1,2,3,4`。
- 修正：去掉 `busi_order_no` 的 group by，改为 `array_distinct(split(...)) AS busi_order_no_array`，或 `explode` 后单独建关联表。
- 原因：数组字段参与 group by 在不同引擎下行为不一致，且会导致同一 orderid+user_id+dt 拆成多行，后续 join base 时金额被重复计算。

#### ❌ 修正 13：refund.user_id 口径与 flight_info.user_id 不一致
- 原逻辑：refund.user_id = `extdata['user_id']`，flight_info.user_id 来自订单表。
- 修正：统一以 `flight_info.user_id` 为锚，refund 表用 orderid 关联 flight_info 取 user_id，而非直接用 extdata。
- 原因：extdata['user_id'] 可能为空或与下单人不一致（如代付），直接 join 会导致跨表用户对不齐。

---

## 七、base 表（用户-日聚合）口径

### 7.1 字段字典

| 字段 | 含义 |
|---|---|
| dt | 日期 |
| user_id | 用户ID |
| order_array | 当日订单号数组 |
| pay_info_array | 当日支付工具数组 |
| dt_total_order_cnt | 当日订单数 |
| dt_distinct_uid_cnt | 当日去重UID数 |
| dt_total_order_amount | 当日订单总金额 |
| dt_pay_ok_order_cnt | 当日支付成功订单数 |
| dt_pay_ok_order_amount | 当日支付成功金额 |
| dt_ticket_success_order_cnt | 当日出票完成数 |
| dt_ticket_cancelld_order_cnt | 当日取消数 |
| dt_refund_order_cnt | 当日退款订单数（含退款中） |
| dt_gq_order_cnt | 当日改签数（含申请中） |
| dt_refund_amount | 当日退款金额 |

### 7.2 口径修正项

#### ❌ 修正 14：`dt_distinct_uid_cnt` 在 group by user_id 后恒等于 1
- 原逻辑：`count(distinct uid)` 且 `group by user_id`。
- 修正：删除该字段，或改为 `count(distinct order_no)` 已由 `dt_total_order_cnt` 覆盖。
- 原因：已按 user_id 分组，组内 uid 去重必为 1，无信息量。

#### ❌ 修正 15：refund join base 产生笛卡尔积放大
- 原逻辑：`base left join refund on A.dt=B.dt and A.user_id=B.user_id`，refund 同 user_id+dt 可能有多笔，flight_info 同 user_id+dt 也可能有多笔订单 → join 后行数膨胀 → `sum(refund_amount)` 被重复累加。
- 修正：refund 先聚合到 `user_id × dt` 粒度（`sum(amt) group by user_id, dt`），再 join base。
- 原因：当前写法会导致 `dt_refund_amount` 偏大，直接影响风险率计算。

#### ❌ 修正 16：7 天窗口只算退款订单数，缺退款率
- 原逻辑：`sum(dt_refund_order_cnt) over(... 6 PRECEDING and current)`。
- 修正：同时计算 7 天累计订单数，再相除得 `refund_rate_7d`。
- 原因：单纯退款订单数无法识别风险，高订单量用户退款数天然偏高，需用比率。

#### ❌ 修正 17：comp 关联用 `C.user_id[1]` 不安全
- 原逻辑（注释段）：`left join comp C on A.user_id = C.user_id[1]`。
- 修正：comp 修正 3 后 user_id 为标量，直接 `on A.user_id = C.user_id`，且关联键应是 `order_no`（`contains(order_array, order_no1)`）。
- 原因：数组取下标在空数组时返回 NULL，且假设"一个 order_no 只有一个 user_id"未校验。

---

## 八、全局口径问题

### ❌ 修正 18：user_id 跨表口径不统一

| 表 | user_id 来源 |
|---|---|
| comp | `array_agg(user_id)` |
| pay_info | `ext_uid` |
| flight_info | `user_id` |
| refund | `extdata['user_id']` |

**统一方案**：以 `flight_info.user_id` 为全局主键，其余表通过 `order_no` 关联 flight_info 取 user_id，避免直接使用各表自带的 user_id 字段。

### ❌ 修正 19：dt 分区过滤不一致
- comp：`dt = '%(DATE)s'` 且 `create_time >= '2026-01-01'`
- pay_info：`dt >= '2026-03-01'`
- flight_info：`dt >= '2026-01-01'`
- refund：`dt >= '2026-01-01'`

**统一方案**：模型训练样本区 `dt >= '2026-03-01'`（pay_info 起始日），回溯特征可放宽到 `2026-01-01`。

---

## 九、修正后字段清单（用于离线表）

见 `sql/01_offline_tables.sql`。
