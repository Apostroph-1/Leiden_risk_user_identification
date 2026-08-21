-- =====================================================================
-- Leiden 风险用户识别 - 离线表建表与跑批SQL
-- 约束：线上只允许跑 SQL 产出离线表，线下用离线表建模
-- 含义见 docs/01_field_dictionary.md 与 docs/02_field_design.md
-- =====================================================================

-- #####################################################################
-- Layer 2: DWD 离线明细表（线上产出）
-- #####################################################################

-- -------------------------------------------------------------------
-- 2.1 机票订单 DWD
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dwd_flight_order_di (
    dt              STRING          COMMENT '日期分区 yyyy-MM-dd',
    order_no        STRING          COMMENT '订单号 国内取main_order_no 国际取order_no',
    user_id         STRING          COMMENT '用户ID 全局主键',
    username        STRING          COMMENT 'Qunar用户名',
    status_code     INT             COMMENT '原始状态码',
    status_name     STRING          COMMENT '状态中文名',
    pay_ok          INT             COMMENT '是否支付成功 0/1',
    is_ticket_success INT           COMMENT '是否出票成功 0/1',
    is_apply_refund INT             COMMENT '是否申请退款 refund_apply_time非空',
    total_price     DECIMAL(18,2)   COMMENT '订单总价',
    total_ticket_price DECIMAL(18,2) COMMENT '票面总价',
    ip              STRING          COMMENT '下单IP',
    contact_mob     STRING          COMMENT '联系人手机 下单人',
    dep_date        STRING          COMMENT '出发日期',
    arr_time        STRING          COMMENT '到达时间',
    cabin           STRING          COMMENT '舱位',
    flight_num      STRING          COMMENT '航班号',
    passenger_name  ARRAY<STRING>   COMMENT '乘机人姓名',
    passenger_card_num ARRAY<STRING> COMMENT '乘机人证件号',
    passenger_mobile ARRAY<STRING>  COMMENT '乘机人手机',
    pay_tool_id     STRING          COMMENT '支付工具标识 卡号后6前4 或 thirdUid',
    pay_brand_name  STRING          COMMENT '支付品牌',
    pay_time        TIMESTAMP       COMMENT '支付时间',
    refund_amount   DECIMAL(18,2)   COMMENT '退款金额 来自refund表'
) COMMENT '机票订单DWD明细'
PARTITIONED BY (dt STRING)
STORED AS ORC;


-- 跑批：每日 T+1 产出
INSERT OVERWRITE TABLE leiden.dwd_flight_order_di PARTITION(dt='${DATE}')
SELECT
    A.dt,
    IF(A.dom_inter = 1, A.main_order_no, A.order_no) AS order_no,
    A.user_id,
    A.qunar_username AS username,
    A.status AS status_code,
    CASE A.status
        WHEN 0  THEN '订座成功等待支付'
        WHEN 1  THEN '支付成功等待出票'
        WHEN 2  THEN '出票完成'
        WHEN 3  THEN '出票完成'
        WHEN 5  THEN '出票中'
        WHEN 12 THEN '订单取消'
        WHEN 20 THEN '等待座位确认'
        WHEN 30 THEN '退款待确认'
        WHEN 31 THEN '待退款'
        WHEN 39 THEN '退款完成'
        WHEN 40 THEN '改签申请中'
        WHEN 42 THEN '改签完成'
        WHEN 50 THEN '未出票申请退款'
        WHEN 51 THEN '订座成功等待价格确认'
        WHEN 62 THEN '订单超时'
        WHEN 90 THEN '时间超时自动取消'
        WHEN 91 THEN '订单超时取消'
        WHEN 93 THEN '退款中'
        WHEN 95 THEN '退款完成自动'
        WHEN 99 THEN '已拆分'
        WHEN 101 THEN '非旗舰店出票成功'
        ELSE 'unknown'
    END AS status_name,
    A.pay_ok,
    A.is_ticket_success,
    IF(A.refund_apply_time IS NOT NULL, 1, 0) AS is_apply_refund,
    A.total_price,
    A.total_ticket_price,
    A.ip,
    A.contact_mob,
    A.dep_date,
    A.arr_time,
    A.cabin,
    A.flight_num,
    P.guest_name AS passenger_name,
    P.guest_card_num AS passenger_card_num,
    P.guest_mobile AS passenger_mobile,
    C.pay_tool_id,
    C.pay_brand_name,
    C.pay_time,
    R.refund_amount
FROM flight.dwd_ord_wide_order_di A
LEFT JOIN (
    SELECT
        IF(o_dom_inter = 1, o_main_order_no, o_order_no) AS order_no,
        o_uid AS uid,
        array_remove(array_distinct(array_agg(p_passenger_name)), NULL) AS guest_name,
        array_remove(array_distinct(array_agg(p_card_num)), NULL) AS guest_card_num,
        array_remove(array_distinct(array_agg(p_mobile)), NULL) AS guest_mobile
    FROM flight.dwd_ord_wide_order_ticket_di
    WHERE dt = '${DATE}'
    GROUP BY 1, 2
) P ON P.order_no = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
LEFT JOIN (
    SELECT
        orderid,
        MAX(COALESCE(cardnumf6l4join, regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1))) AS pay_tool_id,
        MAX(pay_brand_name) AS pay_brand_name,
        MAX(pay_time) AS pay_time
    FROM pp_pub.dwd_fin_sub_trade_payment_account_detail_di
    WHERE dt = '${DATE}'
      AND COALESCE(cardnumf6l4join, regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) IS NOT NULL
    GROUP BY 1
) C ON C.orderid = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
LEFT JOIN (
    -- 修正13: refund先聚合到 orderid 粒度，避免笛卡尔积
    SELECT
        orderid,
        SUM(amt) AS refund_amount
    FROM (
        SELECT
            d AS dt,
            orderid,
            extdata['user_id'] AS user_id,
            amt
        FROM pp_pub.dwd__qunar_selfpayord_di
        WHERE d = '${DATE}'
          AND order_type_change LIKE '%机票%'
          AND opertype = '退款'
    ) R0
    GROUP BY orderid
) R ON R.orderid = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
WHERE A.dt = '${DATE}';


-- -------------------------------------------------------------------
-- 2.2 客诉赔付 DWD（修正1-6）
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dwd_callcenter_compensation_di (
    dt                  STRING          COMMENT '日期分区',
    order_no            STRING          COMMENT '订单号',
    biz_line            STRING          COMMENT '业务线',
    user_id             STRING          COMMENT '用户ID MAX(user_id) 标量',
    problem_name        ARRAY<STRING>   COMMENT '问题类型',
    compensation_status ARRAY<STRING>   COMMENT '赔付状态',
    compensation_amount DECIMAL(18,2)   COMMENT '赔付金额 仅pay_success求和',
    refund_amount       DECIMAL(18,2)   COMMENT '退款金额 仅pay_success求和 修正拼写',
    total_amount        DECIMAL(18,2)   COMMENT '赔付总金额',
    audit_result        ARRAY<STRING>   COMMENT '审核结果',
    reject_back         ARRAY<STRING>   COMMENT '驳回原因',
    responser           STRING          COMMENT '责任人',
    detail_reason       ARRAY<STRING>   COMMENT '详细原因',
    first_create_time   TIMESTAMP       COMMENT '首次发起时间 MIN(create_time)',
    last_update_time    TIMESTAMP       COMMENT '最后更新时间 MAX(update_time)',
    auto_pay            STRING          COMMENT '是否自动赔付',
    del_flag            INT             COMMENT '删除标记 MAX(del)'
) COMMENT '客诉赔付DWD明细'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dwd_callcenter_compensation_di PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    order_no,
    MAX(biz_line) AS biz_line,
    MAX(user_id) AS user_id,                           -- 修正3
    array_distinct(array_agg(problem_name)) AS problem_name,
    array_distinct(array_agg(compensation_status)) AS compensation_status,
    ROUND(SUM(CASE WHEN compensation_status = 'pay_success' THEN compensation_amount ELSE 0 END), 2) AS compensation_amount,  -- 修正2
    ROUND(SUM(CASE WHEN compensation_status = 'pay_success' THEN refund_amount ELSE 0 END), 2) AS refund_amount,             -- 修正1
    ROUND(SUM(CASE WHEN compensation_status = 'pay_success' THEN total_amount ELSE 0 END), 2) AS total_amount,
    array_distinct(array_agg(audit_result)) AS audit_result,
    array_distinct(array_agg(reject_back)) AS reject_back,
    MAX(responser) AS responser,
    array_distinct(array_agg(detail_reason)) AS detail_reason,
    MIN(create_time) AS first_create_time,             -- 修正5
    MAX(update_time) AS last_update_time,
    MAX(auto_pay) AS auto_pay,
    CAST(MAX(del) AS INT) AS del_flag                  -- 修正4
FROM default.ods_callcenterdb_cc_compensation
WHERE dt = '${DATE}'
  AND create_time >= '2026-01-01'
GROUP BY order_no;


-- -------------------------------------------------------------------
-- 2.3 酒店 DWD（伪代码，需业务方确认源表）
-- -------------------------------------------------------------------
-- CREATE TABLE IF NOT EXISTS leiden.dwd_hotel_order_di (...);
-- 同结构思路：订单粒度 + 支付工具 + 入住人 + 退款金额 + 客诉关联


-- -------------------------------------------------------------------
-- 2.4 门票 DWD（伪代码，需业务方确认源表）
-- -------------------------------------------------------------------
-- CREATE TABLE IF NOT EXISTS leiden.dwd_ticket_order_di (...);


-- #####################################################################
-- Layer 3: DWS 用户-日宽表（线上产出 or 线下mysql均可）
-- 建议线上产出 dws_user_biz_daily，线下再聚合 dws_user_cross_biz_daily
-- #####################################################################

-- -------------------------------------------------------------------
-- 3.1 按业务线用户-日宽表
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dws_user_biz_daily (
    dt                          STRING          COMMENT '日期',
    biz_line                    STRING          COMMENT '业务线',
    user_id                     STRING          COMMENT '用户ID',
    dt_total_order_cnt          BIGINT          COMMENT '当日订单数',
    dt_pay_ok_order_cnt         BIGINT          COMMENT '当日支付成功订单数',
    dt_pay_ok_order_amount      DECIMAL(18,2)   COMMENT '当日支付成功金额',
    dt_ticket_success_order_cnt BIGINT          COMMENT '当日履约成功数',
    dt_cancel_order_cnt         BIGINT          COMMENT '当日取消数',
    dt_refund_order_cnt         BIGINT          COMMENT '当日退款订单数 含退款中',
    dt_refund_amount            DECIMAL(18,2)   COMMENT '当日退款金额',
    dt_gq_order_cnt             BIGINT          COMMENT '当日改签数 仅机票',
    dt_compensation_cnt         BIGINT          COMMENT '当日客诉赔付笔数',
    dt_compensation_amount      DECIMAL(18,2)   COMMENT '当日赔付金额',
    dt_distinct_pay_tool_cnt    BIGINT          COMMENT '当日不同支付工具数',
    dt_distinct_ip_cnt          BIGINT          COMMENT '当日不同IP数',
    dt_distinct_contact_mob_cnt BIGINT          COMMENT '当日不同联系人手机数',
    dt_distinct_passenger_cnt   BIGINT          COMMENT '当日不同乘机人/入住人/游客数',
    dt_max_order_amount         DECIMAL(18,2)   COMMENT '当日单笔最大金额'
) COMMENT '用户-业务线-日宽表'
PARTITIONED BY (dt STRING, biz_line STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dws_user_biz_daily PARTITION(dt='${DATE}', biz_line='机票')
SELECT
    '${DATE}' AS dt,
    '机票' AS biz_line,
    A.user_id,
    COUNT(DISTINCT A.order_no) AS dt_total_order_cnt,
    COUNT(DISTINCT IF(A.pay_ok = 1, A.order_no, NULL)) AS dt_pay_ok_order_cnt,
    SUM(IF(A.pay_ok = 1, A.total_price, 0)) AS dt_pay_ok_order_amount,
    COUNT(DISTINCT IF(A.is_ticket_success = 1, A.order_no, NULL)) AS dt_ticket_success_order_cnt,
    COUNT(DISTINCT IF(A.status_name = '订单取消', A.order_no, NULL)) AS dt_cancel_order_cnt,
    COUNT(DISTINCT IF(A.status_name IN ('退款完成','退款完成自动','退款中','待退款','退款待确认'), A.order_no, NULL)) AS dt_refund_order_cnt,
    COALESCE(SUM(A.refund_amount), 0) AS dt_refund_amount,
    COUNT(DISTINCT IF(A.status_name IN ('改签完成','改签申请中'), A.order_no, NULL)) AS dt_gq_order_cnt,
    COALESCE(COUNT(DISTINCT C.order_no), 0) AS dt_compensation_cnt,
    COALESCE(SUM(C.total_amount), 0) AS dt_compensation_amount,
    SIZE(array_distinct(A.pay_tool_id_arr)) AS dt_distinct_pay_tool_cnt,   -- 见下方子查询
    SIZE(array_distinct(A.ip_arr)) AS dt_distinct_ip_cnt,
    SIZE(array_distinct(A.mob_arr)) AS dt_distinct_contact_mob_cnt,
    SIZE(array_distinct(A.psg_arr)) AS dt_distinct_passenger_cnt,
    MAX(A.total_price) AS dt_max_order_amount
FROM (
    SELECT
        user_id,
        order_no,
        pay_ok,
        is_ticket_success,
        status_name,
        total_price,
        refund_amount,
        pay_tool_id AS pay_tool_id_arr,    -- 若已是标量，用 array 若无值为 array(null)
        ip AS ip_arr,
        contact_mob AS mob_arr,
        passenger_name AS psg_arr
    FROM leiden.dwd_flight_order_di
    WHERE dt = '${DATE}'
) A
LEFT JOIN (
    SELECT order_no, SUM(total_amount) AS total_amount
    FROM leiden.dwd_callcenter_compensation_di
    WHERE dt = '${DATE}'
      AND biz_line = '机票'
    GROUP BY order_no
) C ON C.order_no = A.order_no
GROUP BY A.user_id;


-- -------------------------------------------------------------------
-- 3.2 跨业务线用户-日汇总
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dws_user_cross_biz_daily (
    dt                              STRING,
    user_id                         STRING,
    dt_cross_order_cnt              BIGINT,
    dt_cross_biz_cnt                BIGINT,
    dt_cross_pay_ok_amount          DECIMAL(18,2),
    dt_cross_refund_amount          DECIMAL(18,2),
    dt_cross_compensation_amount    DECIMAL(18,2),
    dt_cross_distinct_pay_tool_cnt  BIGINT,
    dt_cross_distinct_ip_cnt        BIGINT,
    dt_cross_distinct_mobile_cnt    BIGINT
) COMMENT '跨业务线用户-日汇总'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dws_user_cross_biz_daily PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    user_id,
    SUM(dt_total_order_cnt) AS dt_cross_order_cnt,
    COUNT(DISTINCT biz_line) AS dt_cross_biz_cnt,
    SUM(dt_pay_ok_order_amount) AS dt_cross_pay_ok_amount,
    SUM(dt_refund_amount) AS dt_cross_refund_amount,
    SUM(dt_compensation_amount) AS dt_cross_compensation_amount,
    SUM(dt_distinct_pay_tool_cnt) AS dt_cross_distinct_pay_tool_cnt,
    SUM(dt_distinct_ip_cnt) AS dt_cross_distinct_ip_cnt,
    SUM(dt_distinct_contact_mob_cnt) AS dt_cross_distinct_mobile_cnt
FROM leiden.dws_user_biz_daily
WHERE dt = '${DATE}'
GROUP BY user_id;


-- #####################################################################
-- Layer 4: 特征表（建议线下 python 产出后写入 mysql）
-- 线上 SQL 版本用于校验 python 特征口径一致性
-- #####################################################################

-- 7/30/90 日滚动特征 - 以30d为例
CREATE TABLE IF NOT EXISTS leiden.feature_user_risk_profile (
    snapshot_dt                 STRING          COMMENT '快照日 T-1',
    user_id                     STRING,
    -- 规模
    order_cnt_7d                BIGINT,
    order_cnt_30d               BIGINT,
    order_cnt_90d               BIGINT,
    pay_ok_amount_7d            DECIMAL(18,2),
    pay_ok_amount_30d           DECIMAL(18,2),
    pay_ok_amount_90d           DECIMAL(18,2),
    cross_biz_cnt_7d            BIGINT,
    cross_biz_cnt_30d           BIGINT,
    cross_biz_cnt_90d           BIGINT,
    -- 风险率
    refund_rate_7d              DECIMAL(5,4),
    refund_rate_30d             DECIMAL(5,4),
    refund_rate_90d             DECIMAL(5,4),
    refund_amount_rate_7d       DECIMAL(5,4),
    refund_amount_rate_30d      DECIMAL(5,4),
    refund_amount_rate_90d      DECIMAL(5,4),
    cancel_rate_7d              DECIMAL(5,4),
    cancel_rate_30d             DECIMAL(5,4),
    cancel_rate_90d             DECIMAL(5,4),
    compensation_rate_7d        DECIMAL(5,4),
    compensation_rate_30d       DECIMAL(5,4),
    compensation_rate_90d       DECIMAL(5,4),
    compensation_amount_rate_7d DECIMAL(5,4),
    compensation_amount_rate_30d DECIMAL(5,4),
    compensation_amount_rate_90d DECIMAL(5,4),
    -- 身份聚集
    distinct_pay_tool_cnt_7d    BIGINT,
    distinct_pay_tool_cnt_30d   BIGINT,
    distinct_pay_tool_cnt_90d   BIGINT,
    distinct_ip_cnt_7d          BIGINT,
    distinct_ip_cnt_30d         BIGINT,
    distinct_ip_cnt_90d         BIGINT,
    distinct_contact_mob_cnt_7d BIGINT,
    distinct_contact_mob_cnt_30d BIGINT,
    distinct_contact_mob_cnt_90d BIGINT,
    distinct_passenger_cnt_7d   BIGINT,
    distinct_passenger_cnt_30d  BIGINT,
    distinct_passenger_cnt_90d  BIGINT,
    -- 行为异常
    min_interval_between_order_min_7d  BIGINT       COMMENT '秒',
    max_order_amount_30d       DECIMAL(18,2),
    night_order_cnt_30d        BIGINT              COMMENT '0-6点下单数',
    same_flight_diff_passenger_cnt_30d BIGINT      COMMENT '黄牛识别',
    same_passenger_diff_user_cnt_30d   BIGINT      COMMENT '代购识别',
    cross_biz_burst_cnt_7d     BIGINT,
    -- 客诉
    compensation_reject_cnt_30d BIGINT,
    compensation_auto_pay_rate_30d DECIMAL(5,4),
    distinct_problem_type_cnt_30d BIGINT
) COMMENT '用户风险特征表'
PARTITIONED BY (snapshot_dt STRING)
STORED AS ORC;


-- 30d 窗口特征 SQL（示例）
INSERT OVERWRITE TABLE leiden.feature_user_risk_profile PARTITION(snapshot_dt='${DATE}')
SELECT
    '${DATE}' AS snapshot_dt,
    user_id,
    -- 7d
    SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_total_order_cnt, 0)) AS order_cnt_7d,
    SUM(dt_total_order_cnt) AS order_cnt_30d,
    NULL AS order_cnt_90d,        -- 90d 需更长回溯
    SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_pay_ok_order_amount, 0)) AS pay_ok_amount_7d,
    SUM(dt_pay_ok_order_amount) AS pay_ok_amount_30d,
    NULL AS pay_ok_amount_90d,
    NULL AS cross_biz_cnt_7d,
    NULL AS cross_biz_cnt_30d,
    NULL AS cross_biz_cnt_90d,
    -- refund_rate_7d/30d
    CASE WHEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_total_order_cnt, 0)) > 0
         THEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_refund_order_cnt, 0)) / SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_total_order_cnt, 0))
         ELSE 0 END AS refund_rate_7d,
    CASE WHEN SUM(dt_total_order_cnt) > 0
         THEN SUM(dt_refund_order_cnt) / SUM(dt_total_order_cnt)
         ELSE 0 END AS refund_rate_30d,
    NULL AS refund_rate_90d,
    -- refund_amount_rate
    CASE WHEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_pay_ok_order_amount, 0)) > 0
         THEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_refund_amount, 0)) / SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_pay_ok_order_amount, 0))
         ELSE 0 END AS refund_amount_rate_7d,
    CASE WHEN SUM(dt_pay_ok_order_amount) > 0
         THEN SUM(dt_refund_amount) / SUM(dt_pay_ok_order_amount)
         ELSE 0 END AS refund_amount_rate_30d,
    NULL AS refund_amount_rate_90d,
    -- cancel_rate
    CASE WHEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_total_order_cnt, 0)) > 0
         THEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_cancel_order_cnt, 0)) / SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_total_order_cnt, 0))
         ELSE 0 END AS cancel_rate_7d,
    CASE WHEN SUM(dt_total_order_cnt) > 0
         THEN SUM(dt_cancel_order_cnt) / SUM(dt_total_order_cnt)
         ELSE 0 END AS cancel_rate_30d,
    NULL AS cancel_rate_90d,
    -- compensation_rate
    CASE WHEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_total_order_cnt, 0)) > 0
         THEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_compensation_cnt, 0)) / SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_total_order_cnt, 0))
         ELSE 0 END AS compensation_rate_7d,
    CASE WHEN SUM(dt_total_order_cnt) > 0
         THEN SUM(dt_compensation_cnt) / SUM(dt_total_order_cnt)
         ELSE 0 END AS compensation_rate_30d,
    NULL AS compensation_rate_90d,
    -- compensation_amount_rate
    CASE WHEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_pay_ok_order_amount, 0)) > 0
         THEN SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_compensation_amount, 0)) / SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_pay_ok_order_amount, 0))
         ELSE 0 END AS compensation_amount_rate_7d,
    CASE WHEN SUM(dt_pay_ok_order_amount) > 0
         THEN SUM(dt_compensation_amount) / SUM(dt_pay_ok_order_amount)
         ELSE 0 END AS compensation_amount_rate_30d,
    NULL AS compensation_amount_rate_90d,
    -- 身份聚集 7/30d
    SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_distinct_pay_tool_cnt, 0)) AS distinct_pay_tool_cnt_7d,
    SUM(dt_distinct_pay_tool_cnt) AS distinct_pay_tool_cnt_30d,
    NULL AS distinct_pay_tool_cnt_90d,
    SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_distinct_ip_cnt, 0)) AS distinct_ip_cnt_7d,
    SUM(dt_distinct_ip_cnt) AS distinct_ip_cnt_30d,
    NULL AS distinct_ip_cnt_90d,
    SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_distinct_contact_mob_cnt, 0)) AS distinct_contact_mob_cnt_7d,
    SUM(dt_distinct_contact_mob_cnt) AS distinct_contact_mob_cnt_30d,
    NULL AS distinct_contact_mob_cnt_90d,
    SUM(IF(dt >= DATE_SUB('${DATE}', 6), dt_distinct_passenger_cnt, 0)) AS distinct_passenger_cnt_7d,
    SUM(dt_distinct_passenger_cnt) AS distinct_passenger_cnt_30d,
    NULL AS distinct_passenger_cnt_90d,
    -- 行为异常：最短订单间隔需用明细，宽表算不了，留给python
    NULL AS min_interval_between_order_min_7d,
    MAX(dt_max_order_amount) AS max_order_amount_30d,
    NULL AS night_order_cnt_30d,
    NULL AS same_flight_diff_passenger_cnt_30d,
    NULL AS same_passenger_diff_user_cnt_30d,
    NULL AS cross_biz_burst_cnt_7d,
    -- 客诉
    NULL AS compensation_reject_cnt_30d,
    NULL AS compensation_auto_pay_rate_30d,
    NULL AS distinct_problem_type_cnt_30d
FROM (
    SELECT dt, user_id, biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, dt_refund_order_cnt, dt_refund_amount,
        dt_cancel_order_cnt, dt_compensation_cnt, dt_compensation_amount,
        dt_distinct_pay_tool_cnt, dt_distinct_ip_cnt, dt_distinct_contact_mob_cnt,
        dt_distinct_passenger_cnt, dt_max_order_amount
    FROM leiden.dws_user_biz_daily
    WHERE dt BETWEEN DATE_SUB('${DATE}', 29) AND '${DATE}'
    -- 30d 窗口内单业务线，如需跨业务线汇总用 dws_user_cross_biz_daily
) T
GROUP BY user_id;


-- #####################################################################
-- Layer 5: 标签表（线下python产出，回溯标注）
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.label_user_risk (
    snapshot_dt             STRING,
    user_id                 STRING,
    is_refund_abuser        INT      COMMENT '退款滥用 30d退款率>=0.5且退款金额率>=0.3',
    is_compensation_abuser  INT      COMMENT '赔付滥用 30d赔付订单率>=0.3且赔付金额率>=0.2',
    is_cancel_abuser        INT      COMMENT '恶意取消 30d取消率>=0.5且取消数>=5',
    is_identity_fraud       INT      COMMENT '身份聚集欺诈 30d不同支付工具/IP/手机号任一>=5',
    is_cross_biz_abuser     INT      COMMENT '跨业务线薅羊毛 30d跨业务线订单>=3且跨业务线赔付率>=0.3',
    is_risk_user            INT      COMMENT '综合风险 上述任一命中=1'
) COMMENT '风险用户标签表'
PARTITIONED BY (snapshot_dt STRING)
STORED AS ORC;
