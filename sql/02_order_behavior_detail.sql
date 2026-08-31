-- =====================================================================
-- 02. 中风险及以上设备 - 订单行为流水（一行一订单，建模取数）
-- =====================================================================
-- 用途：SynchroTrap 同步行为 / N-Gram 行为序列 / 序列图片化的数据底座
-- 产出口径：**一行 = 一个订单**，订单的各环节时间放在同一行的不同列，
--           未发生的环节为空值（不再用 UNION ALL 展开成多行事件）
-- 字段来源：严格限定字段名.xlsx 中实际存在的字段
--   订单表 flight.dwd_ord_wide_order_di：uid / order_no / main_order_no /
--     dom_inter / user_id / create_time / pay_ok / pay_time /
--     is_ticket_success / ticket_time / status / refund_apply_time /
--     refund_complete_time / last_updated / total_price / ip / ip_city /
--     dep_city / arr_city
--   票维度表 flight.dwd_ord_wide_order_ticket_di：o_dom_inter /
--     o_main_order_no / o_order_no / p_passenger_name / p_card_num /
--     p_mobile / o_ip_country / o_ip_province / o_ip_city
--   （注意：订单表没有 ip_country / ip_province，地理三件套从票维度表取）
-- 命名规则：线上参数用 ${target_date} / ${START} / ${END}

WITH base_order AS (
    -- 中高危设备的订单（社区 != '-1' 的名单，与线上 temp 表同口径）
    SELECT
        A.uid                                          AS device_id,
        IF(A.dom_inter = 1, A.main_order_no, A.order_no) AS order_no,
        A.user_order_no,
        A.user_id,
        A.create_time,
        A.pay_ok,
        A.pay_time,
        A.is_ticket_success,
        A.ticket_time,
        A.status,
        A.refund_apply_time,
        A.refund_complete_time,
        A.last_updated,
        A.total_price,
        A.ip,
        A.ip_city,
        A.dep_city,
        A.arr_city
    FROM flight.dwd_ord_wide_order_di A
    JOIN (
        SELECT uid
        FROM temp.temp_tianran_wang_mid_high_community
        WHERE community != '-1'
    ) R ON A.uid = R.uid
    WHERE A.dt >= date_sub('${target_date}', ${START})
      AND A.dt < date_sub('${target_date}', ${END})
      AND A.uid IS NOT NULL AND A.uid NOT IN ('', ' ', 'null', 'NULL')
),
pay_refund AS (
    -- 退款/扣款金额：按 orderid 聚合（沿用宽表 SQL 口径）
    -- 注意：日期只限 ${START}，不限 ${END}（90 天全量，避免分批窗口漏数据）
    SELECT
        orderid,
        SUM(IF(opertype = '退款', amt, 0)) AS refund_amount,
        SUM(IF(opertype = '扣款', amt, 0)) AS pay_amount
    FROM pp_pub.dwd__qunar_selfpayord_di
    WHERE d >= date_sub('${target_date}', ${START})
    GROUP BY orderid
),
pay_method AS (
    -- 支付通道：cardnumf6l4join 或 thirdUid（沿用宽表 SQL 口径）
    -- 注意：日期只限 ${START}（90 天全量，避免分批窗口漏数据）
    SELECT
        orderid,
        COALESCE(cardnumf6l4join,
                 regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) AS pay_tool_id
    FROM pp_pub.dwd_fin_sub_trade_payment_account_detail_di
    WHERE dt >= date_sub('${target_date}', ${START})
      AND COALESCE(cardnumf6l4join,
                   regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) IS NOT NULL
    GROUP BY orderid,
             COALESCE(cardnumf6l4join,
                      regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1))
),
ticket_dim AS (
    -- 票维度：乘机人证件/手机 + 地理信息，聚到 order_no 粒度
    -- （订单表没有 ip_country/ip_province，从票维度表 o_ip_* 取）
    SELECT
        IF(o_dom_inter = 1, o_main_order_no, o_order_no) AS order_no,
        array_remove(array_distinct(array_agg(p_card_num)), NULL) AS card_nums,
        array_remove(array_distinct(array_agg(p_mobile)), NULL)   AS mobiles,
        MAX(o_ip_country)  AS ip_country,
        MAX(o_ip_province) AS ip_province,
        MAX(o_ip_city)     AS ip_city_t
    FROM flight.dwd_ord_wide_order_ticket_di
    WHERE dt >= date_sub('${target_date}', ${START})
      AND dt < date_sub('${target_date}', ${END})
    GROUP BY 1
),
comp AS (
    -- 赔付：pay_success 口径（沿用宽表 SQL，AVG=MAX 判单条）
    -- 注意：order_no 限定在 base_order 范围内，控制扫描量
    SELECT
        order_no AS order_no1,
        ROUND(IF(
            AVG(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount END)
              != MAX(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount END),
            SUM(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount ELSE 0 END),
            AVG(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount END)
        ), 2) AS compensation_amount
    FROM default.ods_callcenterdb_cc_compensation
    WHERE dt = '%(DATE)s'
      AND order_no IN (SELECT order_no FROM base_order)
    GROUP BY 1
)
SELECT
    B.device_id,
    B.order_no,
    B.user_order_no,
    B.user_id,
    -- 订单生命周期各环节时间（一行一订单，未发生为空）
    B.create_time           AS create_time,           -- 下单
    B.pay_time              AS pay_time,              -- 支付（未支付为空）
    B.ticket_time           AS ticket_time,           -- 出票（未出票为空）
    B.refund_apply_time     AS refund_apply_time,     -- 退款申请（无退款为空）
    B.refund_complete_time  AS refund_complete_time,  -- 退款完成（未完成为空）
    B.last_updated          AS last_updated,          -- 最后更新（取消时间近似）
    -- 订单状态快照
    B.status,
    B.pay_ok,
    B.is_ticket_success,
    B.total_price           AS order_amount,
    PR.refund_amount,
    PR.pay_amount,
    C.compensation_amount,
    -- 约束对象（SynchroTrap Constraint Object）
    B.ip,
    B.ip_city,
    T.ip_country,
    T.ip_province,
    B.dep_city,
    B.arr_city,
    PM.pay_tool_id,
    -- 乘机人（数组列，一单多人）
    T.card_nums,
    T.mobiles
FROM base_order B
LEFT JOIN ticket_dim T  ON B.order_no = T.order_no
LEFT JOIN pay_method PM ON B.user_order_no = PM.orderid
LEFT JOIN pay_refund PR ON B.user_order_no = PR.orderid
LEFT JOIN comp C        ON B.order_no = C.order_no1;
