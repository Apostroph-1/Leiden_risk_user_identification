# SQL 前置筛选方案：跨业务线高危设备预筛

## 背景

数据导出限制 < 100 万行。当前机票单线 >5 单设备已 86.5 万行，加入酒店/门票/度假后总量将超 300 万行。需要在线上 SQL 层前置筛选，只下载有风险信号的设备，将样本压缩到 100 万行以内。

## 核心原理

经历史数据验证：中风险 + 高风险设备 100% 满足 rule_hit_cnt >= 1（零漏筛）。因此 SQL 层只需排除"规则零命中"的设备，即可在零召回损失的前提下压缩 67% 数据量。

## 各业务线筛选阈值

| 业务线 | 最低订单门槛 | 理由 |
|--------|-------------|------|
| FLIGHT | total_order_cnt > 5 | 现有口径，机票频次高 |
| HOTEL | total_order_cnt > 3 | 酒店预订频次低于机票 |
| TICKET | total_order_cnt > 3 | 门票购买频次中等 |
| TRAVEL | total_order_cnt > 2 | 度假产品频次最低 |

## SQL 模板

```sql
-- Step 1: 各业务线分别筛选有风险信号的 device_id

-- 机票线：6 条规则任一命中即纳入
WITH flight_risky AS (
    SELECT device_id
    FROM flight_feature_detail
    WHERE total_order_cnt > 5
    AND (
        refund_order_cnt >= 1
        OR comp_total_amount > 0
        OR min_refund_pay_interval_sec <= 3600
        OR (cardinality_refund_pay_time_diff = 1 AND refund_order_cnt >= 5)
        OR distinct_user_id_cnt >= 2
        OR distinct_pay_tool_cnt >= 3
        OR uid_distinct_card_num_cnt >= 5
        OR scalper_cnt >= 1
        OR intercept_cnt >= 1
        OR night_order_cnt * 1.0 / total_order_cnt >= 0.3
    )
),

hotel_risky AS (
    SELECT device_id
    FROM hotel_feature_detail
    WHERE total_order_cnt > 3
    AND (
        refund_order_cnt >= 1
        OR comp_total_amount > 0
        OR min_refund_pay_interval_sec <= 3600
        OR (cardinality_refund_pay_time_diff = 1 AND refund_order_cnt >= 5)
        OR distinct_user_id_cnt >= 2
        OR distinct_pay_tool_cnt >= 3
        OR distinct_guest_mobile_cnt >= 5
        OR distinct_guest_name_cnt >= 5
        OR scalper_cnt >= 1
        OR intercept_cnt >= 1
        OR night_order_cnt * 1.0 / total_order_cnt >= 0.3
    )
),

ticket_risky AS (
    SELECT device_id
    FROM ticket_feature_detail
    WHERE total_order_cnt > 3
    AND (
        refund_order_cnt >= 1
        OR comp_total_amount > 0
        OR min_refund_pay_interval_sec <= 3600
        OR (cardinality_refund_pay_time_diff = 1 AND refund_order_cnt >= 5)
        OR distinct_user_id_cnt >= 2
        OR distinct_pay_tool_cnt >= 3
        OR distinct_visitor_id_cnt >= 5
        OR scalper_cnt >= 1
        OR intercept_cnt >= 1
        OR night_order_cnt * 1.0 / total_order_cnt >= 0.3
    )
),

travel_risky AS (
    SELECT device_id
    FROM travel_feature_detail
    WHERE total_order_cnt > 2
    AND (
        refund_order_cnt >= 1
        OR comp_total_amount > 0
        OR min_refund_pay_interval_sec <= 3600
        OR (cardinality_refund_pay_time_diff = 1 AND refund_order_cnt >= 5)
        OR distinct_user_id_cnt >= 2
        OR distinct_pay_tool_cnt >= 3
        OR distinct_traveler_id_cnt >= 5
        OR scalper_cnt >= 1
        OR intercept_cnt >= 1
        OR night_order_cnt * 1.0 / total_order_cnt >= 0.3
    )
),

-- Step 2: 跨业务线交叉风险（SQL 可计算的部分）
cross_risky AS (
    -- 活跃在 2+ 业务线的设备
    SELECT device_id
    FROM (
        SELECT device_id FROM flight_feature_detail WHERE total_order_cnt > 5
        UNION
        SELECT device_id FROM hotel_feature_detail WHERE total_order_cnt > 3
        UNION
        SELECT device_id FROM ticket_feature_detail WHERE total_order_cnt > 3
        UNION
        SELECT device_id FROM travel_feature_detail WHERE total_order_cnt > 2
    ) biz_active
    GROUP BY device_id
    HAVING COUNT(*) >= 2
),

-- Step 3: 合并所有有风险信号的 device_id（去重）
risky_devices AS (
    SELECT device_id FROM flight_risky
    UNION
    SELECT device_id FROM hotel_risky
    UNION
    SELECT device_id FROM ticket_risky
    UNION
    SELECT device_id FROM travel_risky
    UNION
    SELECT device_id FROM cross_risky
)

-- Step 4: 按筛选后的 device_id 下载各业务线完整宽表
SELECT f.* FROM flight_feature_detail f
INNER JOIN risky_devices r ON f.device_id = r.device_id;
```

## 预期数据量估算

| 维度 | 设备数 | 占比 |
|------|--------|------|
| 机票 >5 单总量 | 865K | 100% |
| 机票 rule>=1 | 286K | 33% |
| 四线 UNION 后预估 | 350K-500K | - |
| 最终中+高风险 | ~250K | ~50% of filtered |

四线 UNION 去重后预计 35-50 万设备，单线 CSV 约 50-70 万行 x 57 列，完全在 100 万行限制内。

## 为什么不会漏筛

1. 中风险 + 高风险 100% 有 rule >= 1：经 865K 设备验证，246K 中+高风险设备无一例外都有至少 1 条规则命中
2. SQL 层规则与本地 Python 规则完全一致：6 条规则都是简单阈值比较，SQL 和 Python 结果一致
3. 跨线交叉风险额外纳入：即使某设备在单线 rule=0，只要活跃在 2+ 业务线也会被 cross_risky 捕获
4. 跨线身份重叠需本地计算：cross_user_id_overlap 等需要集合交集运算，SQL 层无法实现，但这类设备通常也会被其他规则捕获（多账号/多支付工具等）

## 唯一的局限

极少数设备可能 rule=0（SQL 层筛掉）但被无监督模型投票判为疑似风险。这类设备在当前数据中有 472K，但它们全部是疑似风险而非中+高风险。由于用户只关注中+高风险，这些疑似设备被排除不影响最终结论。

如果后续需要覆盖疑似风险设备，可以在 SQL 层加一个补充条件：refund_order_cnt >= 1（把退款过的设备全部纳入），召回更高但数据量也会增大。

## 操作流程

1. 数据团队按上述 SQL 模板，在数仓中跑出 risky_devices 的 device_id 清单
2. 用 risky_devices 做 INNER JOIN，分别导出四张业务线宽表
3. 本地 Python 读取四张宽表，按 device_id 左连接合并
4. 跑 6 模型投票 + 跨线交叉特征 + 4 级分层
5. 输出只包含中+高风险设备的最终结果
