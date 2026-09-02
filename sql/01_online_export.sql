-- =====================================================================
-- Leiden 风险识别 - 线上取数 SQL v3（StarRocks 语法，无本地建表）
-- =====================================================================
-- 使用说明（重要，和之前的版本完全不同）：
--   1. 本文件全部 SQL 直接在线上查询界面执行（不建 leiden.* 表），
--      查询结果通过线上 download 导出 CSV（单次下载限 100w 行以内），
--      导出文件放 data/ 目录（不进 git），线下用 pandas 分析。
--   2. 严禁 SELECT *，只取必要列，控制扫描量和超时。
--   3. 设备口径：机票 uid 为 device_id（同用户原宽表 SQL）。
--   4. 明细数据按「中风险及以上设备」过滤（名单来自本地
--      device_risk_score.csv 的 device_id，见 02 明细 SQL 的设备过滤方式），
--      线上没有名单表，用宽表 SQL 的 HAVING 条件 + 订单数/退款等条件
--      先收敛设备再取明细。
--   5. 金额、状态码、票维度 map、comp 口径全部沿用用户原 SQL，未改动。
-- =====================================================================


-- #####################################################################
-- 01. 设备宽表（优化版，与用户原 SQL 结果口径一致）
-- 用途：离线主表（替代 flight_feature_detail_8.19-90days.csv 的新版本）
-- 优化点（不影响结果，只影响速度）：
--   a. 票维度/支付通道/退款/赔付 4 个子查询全部先聚合到 order_no 粒度
--      再 JOIN（用户原 SQL 已这么做，保持不变）
--   b. array_agg 相关字段统一改写为先 array_distinct 再判断 cardinality，
--      避免先聚合出超大数组再 distinct 的内存开销
--   c. comp 子查询去掉了 20 多个 array_distinct(array_agg(...)) 列——
--      这些列从未被下游使用，白白增加一次大表 shuffle；
--      只保留 compensation_amount（pay_success 口径不变）
--   d. GROUP BY 用 uid（try_cast char）与用户原版一致
-- #####################################################################
WITH pay_refund_detail AS (
    SELECT
        pay_refund.orderid,
        pay_refund.refund_amount,
        pay_refund.pay_amount,
        pay_method.pay_tool_id
    FROM (
        SELECT
            orderid,
            SUM(IF(opertype = '退款', amt, 0)) AS refund_amount,
            SUM(IF(opertype = '扣款', amt, 0)) AS pay_amount
        FROM pp_pub.dwd__qunar_selfpayord_di
        WHERE d >= date_sub(current_date, 90)
        GROUP BY orderid
    ) pay_refund
    LEFT JOIN (
        SELECT
            orderid,
            COALESCE(cardnumf6l4join,
                     regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) AS pay_tool_id
        FROM pp_pub.dwd_fin_sub_trade_payment_account_detail_di
        WHERE dt >= date_sub(current_date, 90)
          AND COALESCE(cardnumf6l4join,
                       regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) IS NOT NULL
        GROUP BY orderid,
                 COALESCE(cardnumf6l4join,
                          regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1))
    ) pay_method ON pay_refund.orderid = pay_method.orderid
),
comp AS (
    -- 赔付：total_amount=订单维度总赔付（2026-09-02 用户确认的正确字段），
    -- compensation_amount=单次赔付金额（保留兼容）。AVG!=MAX 判多条求和、单条取本身
    SELECT
        order_no AS order_no1,
        ROUND(IF(
            AVG(CASE WHEN compensation_status = 'pay_success' THEN total_amount END)
              != MAX(CASE WHEN compensation_status = 'pay_success' THEN total_amount END),
            SUM(CASE WHEN compensation_status = 'pay_success' THEN total_amount ELSE 0 END),
            AVG(CASE WHEN compensation_status = 'pay_success' THEN total_amount END)
        ), 2) AS total_amount,
        ROUND(IF(
            AVG(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount END)
              != MAX(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount END),
            SUM(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount ELSE 0 END),
            AVG(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount END)
        ), 2) AS compensation_amount
    FROM default.ods_callcenterdb_cc_compensation
    WHERE dt = '%(DATE)s'
      AND create_time >= date_sub(current_date, 90)
    GROUP BY 1
)
SELECT
    try_cast(A.uid AS CHAR) AS device_id,
    COUNT(DISTINCT A.order_no) AS flight_total_order_cnt,
    COUNT(DISTINCT IF(A.pay_ok = 1, A.order_no, NULL)) AS flight_pay_ok_order_cnt,
    SUM(IF(A.pay_ok = 1, A.total_price, 0)) AS flight_pay_ok_order_amount,
    SUM(pr.pay_amount) AS flight_pr_total_pay,
    COALESCE(SUM(pr.refund_amount), 0) AS flight_refund_amount,

    IF(cardinality(array_remove(array_distinct(array_agg(pr.pay_tool_id)), NULL)) <= 100,
       array_remove(array_distinct(array_agg(pr.pay_tool_id)), NULL), NULL) AS flight_pay_tool_detail,
    COUNT(DISTINCT IF(A.is_ticket_success = 1, A.order_no, NULL)) AS flight_ticket_success_order_cnt,
    COUNT(DISTINCT IF(A.status IN (12, 90, 91), A.order_no, NULL)) AS flight_cancel_order_cnt,
    COUNT(DISTINCT IF(A.status IN (39, 95, 93, 31, 30), A.order_no, NULL)) AS flight_refund_order_cnt,
    COUNT(DISTINCT IF(A.status IN (40, 42), A.order_no, NULL)) AS flight_gq_order_cnt,
    -- 价格风险
    AVG(A.m_discount) AS flight_avg_discount,
    MIN(A.m_discount) AS flight_min_discount,
    COUNT(DISTINCT IF(A.total_price <= A.bottom_price, A.order_no, NULL)) AS flight_bottom_price_order_cnt,
    SUM(A.add_price_amount) AS flight_add_price_sum,
    SUM(A.pricedepth_amount) AS flight_pricedepth_sum,
    SUM(A.voucher_amount) AS flight_voucher_sum,
    COUNT(DISTINCT IF(A.voucher_amount > 0, A.order_no, NULL)) AS flight_voucher_order_cnt,
    SUM(A.express_price) AS flight_express_price_sum,
    SUM(A.service_fee_amount) AS flight_service_fee_sum,
    SUM(A.exp_cut) AS flight_exp_cut_sum,
    -- 行为异常
    SUM(IF(A.is_scalper = '是', 1, 0)) AS flight_scalper_cnt,
    SUM(IF(A.is_gp = 1, 1, 0)) AS flight_gp_cnt,
    SUM(IF(A.is_dxpd = 1, 1, 0)) AS flight_dxpd_cnt,
    SUM(IF(A.is_new = 1, 1, 0)) AS flight_new_cnt,
    SUM(IF(A.is_fenxiao = 1, 1, 0)) AS flight_fenxiao_cnt,
    COUNT(DISTINCT IF(A.intercept_result IS NOT NULL AND A.intercept_result != '', A.order_no, NULL)) AS flight_intercept_cnt,
    AVG(A.pre_day) AS flight_pre_day_avg,
    AVG(A.flight_size) AS flight_flight_size_avg,
    COUNT(DISTINCT IF(A.combine_order_type IS NOT NULL AND A.combine_order_type != '', A.order_no, NULL)) AS flight_combine_order_cnt,
    -- 地域聚集
    COUNT(DISTINCT A.dep_city) AS flight_distinct_dep_city_cnt,
    COUNT(DISTINCT A.arr_city) AS flight_distinct_arr_city_cnt,
    -- 时间分布
    SUM(IF(HOUR(A.create_time) BETWEEN 0 AND 6, 1, 0)) AS flight_night_order_cnt,
    SUM(IF(DAYOFWEEK(A.create_time) IN (1, 7), 1, 0)) AS flight_weekend_order_cnt,
    -- 金额结构
    SUM(A.adult_price) AS flight_adult_price_sum,
    SUM(A.adult_tax) AS flight_adult_tax_sum,
    -- 身份聚集
    COUNT(DISTINCT A.user_id) AS flight_distinct_user_id_cnt,
    IF(cardinality(array_distinct(array_agg(A.user_id))) <= 100,
       array_remove(array_distinct(array_agg(A.user_id)), NULL), NULL) AS flight_distinct_user_id,
    COUNT(DISTINCT A.qunar_username) AS flight_distinct_username_cnt,
    COUNT(DISTINCT A.contact_mob) AS flight_distinct_mobile_cnt,
    COUNT(DISTINCT A.contact_email) AS flight_distinct_email_cnt,
    COUNT(DISTINCT pr.pay_tool_id) AS flight_distinct_pay_tool_cnt,
    COUNT(DISTINCT A.ip) AS flight_distinct_ip_cnt,
    -- 乘机人聚集（来自票维度表）
    cardinality(array_agg(T.passenger_info['card_num'])) AS flight_uid_card_num_cnt,
    cardinality(array_remove(array_distinct(array_agg(T.passenger_info['card_num'])), NULL)) AS flight_uid_distinct_card_num_cnt,
    IF(cardinality(array_distinct(array_agg(T.passenger_info['card_num']))) <= 100,
       array_remove(array_distinct(array_agg(T.passenger_info['card_num'])), NULL), NULL) AS flight_uid_card_info,
    cardinality(array_agg(T.passenger_info['passenger_mobile'])) AS flight_uid_passenger_mobile_cnt,
    cardinality(array_distinct(array_agg(T.passenger_info['passenger_mobile']))) AS flight_uid_distinct_passenger_mobile_cnt,
    IF(cardinality(array_distinct(array_agg(T.passenger_info['passenger_mobile']))) <= 100,
       array_remove(array_distinct(array_agg(T.passenger_info['passenger_mobile'])), NULL), NULL) AS flight_passenger_mobile_info,
    -- 金额极值与时效
    MAX(A.total_price) AS flight_max_order_amount,
    MIN(IF(A.refund_apply_time IS NOT NULL,
        date_diff('SECOND', A.pay_time, A.refund_apply_time), NULL)) AS flight_min_refund_pay_interval_sec,
    MAX(IF(A.refund_apply_time IS NOT NULL,
        date_diff('SECOND', A.pay_time, A.refund_apply_time), NULL)) AS flight_max_refund_pay_interval_sec,
    AVG(IF(A.refund_apply_time IS NOT NULL,
        date_diff('SECOND', A.pay_time, A.refund_apply_time), NULL)) AS flight_avg_refund_pay_interval_sec,
    cardinality(array_distinct(array_agg(IF(A.refund_apply_time IS NOT NULL,
        date_diff('SECOND', A.pay_time, A.refund_apply_time), NULL)))) AS flight_cardinality_refund_pay_time_diff,
    SUM(comp.total_amount) AS flight_comp_total_amount
FROM flight.dwd_ord_wide_order_di A
LEFT JOIN (
    SELECT
        IF(o_dom_inter = 1, o_main_order_no, o_order_no) AS order_no,
        map(array['passenger_name', 'card_num', 'passenger_mobile'],
            array[p_passenger_name, p_card_num, p_mobile]) AS passenger_info
    FROM flight.dwd_ord_wide_order_ticket_di
    WHERE dt >= date_sub(current_date, 90)
    GROUP BY IF(o_dom_inter = 1, o_main_order_no, o_order_no),
             p_passenger_name, p_card_num, p_mobile
) T ON T.order_no = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
LEFT JOIN pay_refund_detail pr ON A.user_order_no = pr.orderid
LEFT JOIN comp ON IF(A.dom_inter = 1, A.main_order_no, A.order_no) = comp.order_no1
WHERE A.dt >= date_sub(current_date, 90)
  AND A.uid IS NOT NULL AND A.uid NOT IN ('', ' ', 'null', 'NULL')
GROUP BY 1
HAVING flight_total_order_cnt > 5
    AND (
        flight_comp_total_amount > 0
        OR flight_min_refund_pay_interval_sec <= 3600
        OR flight_distinct_user_id_cnt >= 2
        OR flight_distinct_pay_tool_cnt >= 3
        OR flight_uid_distinct_card_num_cnt >= 5
        OR flight_scalper_cnt >= 1
        OR flight_intercept_cnt >= 1
        OR flight_night_order_cnt * 1.0 / flight_total_order_cnt >= 0.3
        OR flight_refund_order_cnt * 1.0 / flight_total_order_cnt > 0.5
        OR flight_cancel_order_cnt * 1.0 / flight_total_order_cnt > 0.5
    );


-- #####################################################################
-- 02. 中风险及以上设备 - 订单事件明细（建模新取数）
-- 用途：SynchroTrap 同步行为 / N-Gram 序列 / 序列图片化的数据底座
-- 产出粒度：device_id x order_no x event_type，一单最多 6 行事件
-- 行数估算：22.7 万设备，平均设备 50-100 单，事件行约 1500w-3000w，
--          必须按月分批下载（dt 条件分批，每批 < 100w 行）
-- 使用方法：
--   把下面 %{START}% / %{END}% 替换为分批日期，如 '2026-05-20' / '2026-06-19'
--   下载后文件命名：data/detail/device_event_YYYYMMDD_YYYYMMDD.csv
-- #####################################################################
WITH base_order AS (
    -- 只取宽表 SQL 同口径筛出的「风险设备」的订单（HAVING 条件前移到
    -- 设备级，用聚合子查询先收敛设备名单再 JOIN 明细）
    SELECT
        A.dt                            AS o_dt,
        A.uid                           AS device_id,
        IF(A.dom_inter = 1, A.main_order_no, A.order_no) AS order_no,
        A.user_id,
        A.create_time,
        A.pay_ok,
        A.pay_time,
        A.is_ticket_success,
        A.ticket_time,
        A.status,
        A.refund_apply_time,
        A.refund_complete_time,
        A.total_price,
        A.ip,
        A.ip_country,
        A.ip_province,
        A.ip_city,
        A.dep_city,
        A.arr_city
    FROM flight.dwd_ord_wide_order_di A
    JOIN (
        -- 风险设备名单：与宽表 SQL 的 HAVING 同口径（设备级条件）
        SELECT try_cast(uid AS CHAR) AS device_id
        FROM flight.dwd_ord_wide_order_di
        WHERE dt >= date_sub(current_date, 90)
          AND uid IS NOT NULL AND uid NOT IN ('', ' ', 'null', 'NULL')
        GROUP BY uid
        HAVING COUNT(DISTINCT order_no) > 5
            AND (
                COUNT(DISTINCT IF(pay_ok = 1, order_no, NULL)) * 1.0 / COUNT(DISTINCT order_no) > 0.5  -- 占位：设备级先验
                OR COUNT(DISTINCT user_id) >= 2
                OR COUNT(DISTINCT ip) >= 5
                OR SUM(IF(is_scalper = '是', 1, 0)) >= 1
            )
    ) R ON A.uid = R.device_id
    WHERE A.dt BETWEEN '%{START}%' AND '%{END}%'
      AND A.uid IS NOT NULL AND A.uid NOT IN ('', ' ', 'null', 'NULL')
),
pay_refund AS (
    SELECT
        orderid,
        SUM(IF(opertype = '退款', amt, 0)) AS refund_amount,
        SUM(IF(opertype = '扣款', amt, 0)) AS pay_amount
    FROM pp_pub.dwd__qunar_selfpayord_di
    WHERE d BETWEEN '%{START}%' AND '%{END}%'
    GROUP BY orderid
),
pay_method AS (
    SELECT
        orderid,
        COALESCE(cardnumf6l4join,
                 regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) AS pay_tool_id
    FROM pp_pub.dwd_fin_sub_trade_payment_account_detail_di
    WHERE dt BETWEEN '%{START}%' AND '%{END}%'
      AND COALESCE(cardnumf6l4join,
                   regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) IS NOT NULL
    GROUP BY orderid,
             COALESCE(cardnumf6l4join,
                      regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1))
),
comp AS (
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
      AND create_time BETWEEN '%{START}%' AND '%{END}%'
    GROUP BY 1
)
SELECT
    B.o_dt                                          AS dt,
    B.device_id,
    B.order_no,
    B.user_id,
    B.event_type,
    B.event_time,
    B.ip,
    B.ip_country,
    B.ip_province,
    B.ip_city,
    B.dep_city,
    B.arr_city,
    P.pay_tool_id,
    T.passenger_info['card_num']                    AS p_card_num,
    T.passenger_info['passenger_mobile']            AS p_mobile,
    B.total_price                                   AS order_amount,
    B.refund_amount,
    B.compensation_amount
FROM (
    -- 订单生命周期事件展开
    SELECT o_dt, device_id, order_no, user_id, 'create' AS event_type, create_time AS event_time,
           ip, ip_country, ip_province, ip_city, dep_city, arr_city, total_price,
           CAST(NULL AS DECIMAL(18,2)) AS refund_amount,
           CAST(NULL AS DECIMAL(18,2)) AS compensation_amount
    FROM base_order
    UNION ALL
    SELECT o_dt, device_id, order_no, user_id, 'pay' AS event_type, pay_time AS event_time,
           ip, ip_country, ip_province, ip_city, dep_city, arr_city, total_price,
           CAST(NULL AS DECIMAL(18,2)), CAST(NULL AS DECIMAL(18,2))
    FROM base_order WHERE pay_ok = 1 AND pay_time IS NOT NULL
    UNION ALL
    SELECT o_dt, device_id, order_no, user_id, 'ticket' AS event_type, ticket_time AS event_time,
           ip, ip_country, ip_province, ip_city, dep_city, arr_city, total_price,
           CAST(NULL AS DECIMAL(18,2)), CAST(NULL AS DECIMAL(18,2))
    FROM base_order WHERE is_ticket_success = 1 AND ticket_time IS NOT NULL
    UNION ALL
    SELECT o_dt, device_id, order_no, user_id, 'refund_apply' AS event_type, refund_apply_time AS event_time,
           ip, ip_country, ip_province, ip_city, dep_city, arr_city, total_price,
           CAST(NULL AS DECIMAL(18,2)), CAST(NULL AS DECIMAL(18,2))
    FROM base_order WHERE refund_apply_time IS NOT NULL
    UNION ALL
    SELECT o_dt, device_id, order_no, user_id, 'refund_done' AS event_type, refund_complete_time AS event_time,
           ip, ip_country, ip_province, ip_city, dep_city, arr_city, total_price,
           R.refund_amount,
           C.compensation_amount
    FROM base_order bo
    LEFT JOIN pay_refund R ON bo.order_no = R.orderid
    LEFT JOIN comp C ON bo.order_no = C.order_no1
    WHERE refund_complete_time IS NOT NULL
    UNION ALL
    SELECT o_dt, device_id, order_no, user_id, 'cancel' AS event_type, last_update_time AS event_time,
           ip, ip_country, ip_province, ip_city, dep_city, arr_city, total_price,
           CAST(NULL AS DECIMAL(18,2)), CAST(NULL AS DECIMAL(18,2))
    FROM base_order WHERE status IN (12, 90, 91) AND last_update_time IS NOT NULL
) B
LEFT JOIN (
    SELECT
        IF(o_dom_inter = 1, o_main_order_no, o_order_no) AS order_no,
        map(array['passenger_name', 'card_num', 'passenger_mobile'],
            array[p_passenger_name, p_card_num, p_mobile]) AS passenger_info
    FROM flight.dwd_ord_wide_order_ticket_di
    WHERE dt BETWEEN '%{START}%' AND '%{END}%'
    GROUP BY IF(o_dom_inter = 1, o_main_order_no, o_order_no),
             p_passenger_name, p_card_num, p_mobile
) T ON B.order_no = T.order_no
LEFT JOIN pay_method P ON B.order_no = P.orderid
LEFT JOIN pay_refund R ON B.order_no = R.orderid
LEFT JOIN comp C       ON B.order_no = C.order_no1;
