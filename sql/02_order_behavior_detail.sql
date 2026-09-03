-- 02 订单明细导出（一行一订单，中高危设备）
-- 用法：线上替换 ${target_date}/${START}/${END}/%(DATE)s 后执行；
--      temp.temp_tianran_wang_mid_high_community 需先上传 02 notebook 产出的中高危设备名单
-- 2026-09-03 v2（用户提供版）：新增 dl_income 结算表（refund/pay 金额 coalesce 双源）；
--      2026-09-02 的⑤指纹字段与 total_amount 唯一赔付口径保持不变
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
dl_income as (SELECT
    order_no,
    -- 付款金额：出票/支付类 check_type 的 income
    SUM(CASE WHEN check_type IN ('出票', '支付', '出保', '废票-出票', '退款-支付')
             THEN CAST(income AS DOUBLE)
             ELSE 0 END) AS pay_amount,
    -- 退款金额：退票/退款类 check_type 的 expense
    SUM(CASE WHEN check_type IN ('退票', '二退', '退差', '改后退', '退佣金',
                                 '废票-退票', '退保', '线下退保',
                                 '结算退款', '退款', '退款-退款')
             THEN CAST(expense AS DOUBLE)
             ELSE 0 END) AS refund_amount
FROM flight.dwd_ord_order_income_all
WHERE dt >= date_sub('${target_date}', ${START}) AND dt < date_sub('${target_date}', ${END})
group by 1
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
    -- 票维度：乘机人证件/手机 + 地理信息 + 航段指纹字段（⑤时序相似性聚类用），聚到 order_no 粒度
    -- （订单表没有 ip_country/ip_province，从票维度表 o_ip_* 取）
    -- ⑤增强字段（2026-09-02）：
    --   flight_nums  航班号数组——航班级指纹，同一航班反复订是团伙强信号
    --   dep_dates / dep_times 行程节奏与时刻偏好
    --   cabins 舱位偏好指纹
    --   passenger_genders / passenger_birthdays 乘机人结构指纹（证件池特征）
    SELECT
        IF(o_dom_inter = 1, o_main_order_no, o_order_no) AS order_no,
        array_remove(array_distinct(array_agg(p_card_num)), NULL) AS card_nums,
        array_remove(array_distinct(array_agg(p_mobile)), NULL)   AS mobiles,
        array_remove(array_distinct(array_agg(s_flight_num)), NULL) AS flight_nums,
        array_remove(array_distinct(array_agg(s_dep_date)), NULL)   AS dep_dates,
        array_remove(array_distinct(array_agg(s_dep_time)), NULL)   AS dep_times,
        array_remove(array_distinct(array_agg(s_cabin)), NULL)      AS cabins,
        MAX(o_ip_country)  AS ip_country,
        MAX(o_ip_province) AS ip_province,
        MAX(o_ip_city)     AS ip_city_t,
        array_remove(array_distinct(array_agg(p_gender)), NULL)    AS passenger_genders,
        array_remove(array_distinct(array_agg(p_birthday)), NULL)  AS passenger_birthdays
    FROM flight.dwd_ord_wide_order_ticket_di
    WHERE dt >= date_sub('${target_date}', ${START})
      AND dt < date_sub('${target_date}', ${END})
    GROUP BY 1
),
comp AS (
    -- 赔付：唯一口径 = comp 表 total_amount（订单维度总赔付，pay_success 状态）
    -- 注意：order_no 限定在 base_order 范围内，控制扫描量
    SELECT
        order_no AS order_no1,
        ROUND(IF(
            -- 仅统计pay_success订单：多条成功（AVG!=MAX）求和；单条取均值（=本身）
            AVG(CASE WHEN compensation_status = 'pay_success' THEN total_amount END)
              != MAX(CASE WHEN compensation_status = 'pay_success' THEN total_amount END),
            SUM(CASE WHEN compensation_status = 'pay_success' THEN total_amount ELSE 0 END),
            AVG(CASE WHEN compensation_status = 'pay_success' THEN total_amount END)
        ), 2) AS total_amount
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
    coalesce(PR.refund_amount,dl.refund_amount) as refund_amount,
    coalesce(B.total_price,PR.pay_amount) as pay_amount,
    C.total_amount,
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
    T.mobiles,
    -- ⑤时序指纹增强字段（2026-09-02）
    T.flight_nums,
    T.dep_dates,
    T.dep_times,
    T.cabins,
    T.passenger_genders,
    T.passenger_birthdays
FROM base_order B
LEFT JOIN ticket_dim T  ON B.order_no = T.order_no
LEFT JOIN dl_income dl on B.order_no = dl.order_no
LEFT JOIN pay_method PM ON B.user_order_no = PM.orderid
LEFT JOIN pay_refund PR ON B.user_order_no = PR.orderid
LEFT JOIN comp C        ON B.order_no = C.order_no1;
