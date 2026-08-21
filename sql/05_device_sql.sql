-- =====================================================================
-- Leiden 风险识别 - 设备号维度特征工程 SQL（StarRocks 版）
-- 约束：
--   1. 严格使用 字段名.xlsx 中的字段，不自行添加
--   2. comp 表保持原样，不修改（字段来自用户首条 SQL 中的 comp 查询）
--   3. 设备号口径：机票 uid / 酒店 device_id / 门票 trace_uid
--   4. StarRocks 语法：PARTITION BY 动态分区 / ARRAY 函数 / BITMAP_UNION 等
-- 源表对照：
--   机票订单：flight.dwd_ord_wide_order_di      (字段名.xlsx sheet=机票-订单表维度字段)
--   机票票维度：flight.dwd_ord_wide_order_ticket_di (字段名.xlsx sheet=机票-票维度表字段)
--   酒店订单：hotel.dwd_ord_order_detail_di      (字段名.xlsx sheet=酒店订单表字段)
--   门票订单：ticket.dwd_ord_order_detail_di     (字段名.xlsx sheet=门票-订单表维度字段)
--   支付退款：pp_pub.dwd__qunar_selfpayord_di    (字段名.xlsx sheet=支付-退款表字段)
--   工单明细：default.ods_callcenterdb_workorder_detail (字段名.xlsx sheet=工单明细字段)
--   客诉赔付：default.ods_callcenterdb_cc_compensation (字段来自用户首条 SQL)
-- =====================================================================

-- #####################################################################
-- 0. 设备-账号映射表（基础表）
-- 字段：device_id(机票uid/酒店device_id/门票trace_uid) / user_id / biz_line / order_no / order_time
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dim_device_user_mapping (
    dt              DATE,
    device_id       VARCHAR(64),
    biz_line        VARCHAR(32),
    user_id         VARCHAR(64),
    first_seen_time DATETIME,
    last_seen_time  DATETIME,
    order_cnt       BIGINT
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id, biz_line, user_id)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


-- 跑批：每日 T+1 产出（StarRocks 支持 INSERT OVERWRITE 指定分区）
INSERT OVERWRITE leiden.dim_device_user_mapping PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    device_id,
    biz_line,
    user_id,
    MIN(order_time) AS first_seen_time,
    MAX(order_time) AS last_seen_time,
    COUNT(DISTINCT order_no) AS order_cnt
FROM (
    -- 机票：uid + user_id + order_no + create_time
    SELECT
        uid AS device_id,
        '机票' AS biz_line,
        user_id,
        order_no,
        create_time AS order_time
    FROM flight.dwd_ord_wide_order_di
    WHERE dt = '${DATE}'
      AND uid IS NOT NULL AND uid != ''
    UNION ALL
    -- 酒店：device_id + user_id + order_no + order_time
    SELECT
        device_id,
        '酒店' AS biz_line,
        user_id,
        order_no,
        order_time
    FROM hotel.dwd_ord_order_detail_di
    WHERE dt = '${DATE}'
      AND data_source = 'hms'
      AND device_id IS NOT NULL AND device_id != ''
    UNION ALL
    -- 门票：trace_uid + trace_uid(作user_id) + order_id + order_create_time
    SELECT
        trace_uid AS device_id,
        '门票' AS biz_line,
        trace_uid AS user_id,
        order_id AS order_no,
        order_create_time
    FROM ticket.dwd_ord_order_detail_di
    WHERE dt = '${DATE}'
      AND trace_uid IS NOT NULL AND trace_uid != ''
) T
GROUP BY device_id, biz_line, user_id;


-- #####################################################################
-- 1. 机票设备-日宽表
-- 源：flight.dwd_ord_wide_order_di + flight.dwd_ord_wide_order_ticket_di
-- 字段严格来自 字段名.xlsx sheet=机票-订单表维度字段 + 机票-票维度表字段
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dws_device_flight_daily (
    dt                              DATE,
    device_id                       VARCHAR(64),
    dt_total_order_cnt              BIGINT,
    dt_pay_ok_order_cnt             BIGINT,
    dt_pay_ok_order_amount          DECIMAL(18,2),
    dt_ticket_success_order_cnt     BIGINT,
    dt_cancel_order_cnt             BIGINT,
    dt_refund_order_cnt             BIGINT,
    dt_refund_amount                DECIMAL(18,2),
    dt_gq_order_cnt                 BIGINT,
    -- 价格风险（字段：discount/m_discount/add_price_amount/bottom_price/pricedepth_amount/voucher_amount/express_price/service_fee_amount/exp_cut）
    dt_avg_discount                 DECIMAL(10,4),
    dt_min_discount                 DECIMAL(10,4),
    dt_bottom_price_order_cnt       BIGINT,
    dt_add_price_sum                DECIMAL(18,2),
    dt_pricedepth_sum               DECIMAL(18,2),
    dt_voucher_sum                  DECIMAL(18,2),
    dt_voucher_order_cnt            BIGINT,
    dt_express_price_sum            DECIMAL(18,2),
    dt_service_fee_sum              DECIMAL(18,2),
    dt_exp_cut_sum                  DECIMAL(18,2),
    -- 行为异常（is_scalper/is_gp/is_dxpd/is_new/is_fenxiao/intercept_result/pre_day/flight_size/combine_order_type）
    dt_scalper_cnt                  BIGINT,
    dt_gp_cnt                       BIGINT,
    dt_dxpd_cnt                     BIGINT,
    dt_new_cnt                      BIGINT,
    dt_fenxiao_cnt                  BIGINT,
    dt_intercept_cnt                BIGINT,
    dt_pre_day_avg                  DECIMAL(10,2),
    dt_flight_size_avg              DECIMAL(10,2),
    dt_combine_order_cnt            BIGINT,
    -- 地域聚集（dep_city/arr_city）
    dt_distinct_dep_city_cnt        BIGINT,
    dt_distinct_arr_city_cnt        BIGINT,
    -- 时间分布（create_time）
    dt_night_order_cnt              BIGINT,
    dt_weekend_order_cnt            BIGINT,
    -- 金额结构（adult_price/adult_tax）
    dt_adult_price_sum              DECIMAL(18,2),
    dt_adult_tax_sum                DECIMAL(18,2),
    -- 身份聚集（user_id/qunar_username/contact_mob/contact_email/ip/pay_tool_id 来自支付表关联）
    dt_distinct_user_id_cnt         BIGINT,
    dt_distinct_username_cnt        BIGINT,
    dt_distinct_mobile_cnt          BIGINT,
    dt_distinct_email_cnt           BIGINT,
    dt_distinct_pay_tool_cnt        BIGINT,
    dt_distinct_ip_cnt              BIGINT,
    dt_distinct_contact_mob_cnt     BIGINT,
    -- 乘机人聚集（p_passenger_name/p_card_num/p_mobile 来自票维度表）
    dt_distinct_passenger_cnt       BIGINT,
    dt_distinct_passenger_card_cnt  BIGINT,
    dt_distinct_passenger_mobile_cnt BIGINT,
    dt_distinct_flight_num_cnt      BIGINT,
    -- 金额极值与时效（total_price/pay_time/ticket_time/refund_apply_time/refund_complete_time）
    dt_max_order_amount             DECIMAL(18,2),
    dt_min_pay_ticket_interval_sec  BIGINT,
    dt_min_refund_pay_interval_sec  BIGINT,
    dt_avg_refund_complete_interval_sec BIGINT
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


INSERT OVERWRITE leiden.dws_device_flight_daily PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    A.uid AS device_id,
    COUNT(DISTINCT A.order_no) AS dt_total_order_cnt,
    COUNT(DISTINCT IF(A.pay_ok = 1, A.order_no, NULL)) AS dt_pay_ok_order_cnt,
    SUM(IF(A.pay_ok = 1, A.total_price, 0)) AS dt_pay_ok_order_amount,
    COUNT(DISTINCT IF(A.is_ticket_success = 1, A.order_no, NULL)) AS dt_ticket_success_order_cnt,
    COUNT(DISTINCT IF(A.status = 12 OR A.status = 90 OR A.status = 91, A.order_no, NULL)) AS dt_cancel_order_cnt,
    COUNT(DISTINCT IF(A.status IN (39, 95, 93, 31, 30), A.order_no, NULL)) AS dt_refund_order_cnt,
    COALESCE(SUM(R.refund_amount), 0) AS dt_refund_amount,
    COUNT(DISTINCT IF(A.status IN (40, 42), A.order_no, NULL)) AS dt_gq_order_cnt,
    -- 价格风险
    AVG(A.m_discount) AS dt_avg_discount,
    MIN(A.m_discount) AS dt_min_discount,
    COUNT(DISTINCT IF(A.total_price <= A.bottom_price, A.order_no, NULL)) AS dt_bottom_price_order_cnt,
    SUM(A.add_price_amount) AS dt_add_price_sum,
    SUM(A.pricedepth_amount) AS dt_pricedepth_sum,
    SUM(A.voucher_amount) AS dt_voucher_sum,
    COUNT(DISTINCT IF(A.voucher_amount > 0, A.order_no, NULL)) AS dt_voucher_order_cnt,
    SUM(A.express_price) AS dt_express_price_sum,
    SUM(A.service_fee_amount) AS dt_service_fee_sum,
    SUM(A.exp_cut) AS dt_exp_cut_sum,
    -- 行为异常
    SUM(IF(A.is_scalper = '是', 1, 0)) AS dt_scalper_cnt,
    SUM(IF(A.is_gp = 1, 1, 0)) AS dt_gp_cnt,
    SUM(IF(A.is_dxpd = 1, 1, 0)) AS dt_dxpd_cnt,
    SUM(IF(A.is_new = 1, 1, 0)) AS dt_new_cnt,
    SUM(IF(A.is_fenxiao = 1, 1, 0)) AS dt_fenxiao_cnt,
    COUNT(DISTINCT IF(A.intercept_result IS NOT NULL AND A.intercept_result != '', A.order_no, NULL)) AS dt_intercept_cnt,
    AVG(A.pre_day) AS dt_pre_day_avg,
    AVG(A.flight_size) AS dt_flight_size_avg,
    COUNT(DISTINCT IF(A.combine_order_type IS NOT NULL AND A.combine_order_type != '', A.order_no, NULL)) AS dt_combine_order_cnt,
    -- 地域聚集
    COUNT(DISTINCT A.dep_city) AS dt_distinct_dep_city_cnt,
    COUNT(DISTINCT A.arr_city) AS dt_distinct_arr_city_cnt,
    -- 时间分布
    SUM(IF(HOUR(A.create_time) BETWEEN 0 AND 6, 1, 0)) AS dt_night_order_cnt,
    SUM(IF(DAYOFWEEK(A.create_time) IN (1, 7), 1, 0)) AS dt_weekend_order_cnt,
    -- 金额结构
    SUM(A.adult_price) AS dt_adult_price_sum,
    SUM(A.adult_tax) AS dt_adult_tax_sum,
    -- 身份聚集
    COUNT(DISTINCT A.user_id) AS dt_distinct_user_id_cnt,
    COUNT(DISTINCT A.qunar_username) AS dt_distinct_username_cnt,
    COUNT(DISTINCT A.contact_mob) AS dt_distinct_mobile_cnt,
    COUNT(DISTINCT A.contact_email) AS dt_distinct_email_cnt,
    COUNT(DISTINCT P.pay_tool_id) AS dt_distinct_pay_tool_cnt,
    COUNT(DISTINCT A.ip) AS dt_distinct_ip_cnt,
    COUNT(DISTINCT A.contact_mob) AS dt_distinct_contact_mob_cnt,
    -- 乘机人聚集（来自票维度表）
    COUNT(DISTINCT T.p_passenger_name) AS dt_distinct_passenger_cnt,
    COUNT(DISTINCT T.p_card_num) AS dt_distinct_passenger_card_cnt,
    COUNT(DISTINCT T.p_mobile) AS dt_distinct_passenger_mobile_cnt,
    COUNT(DISTINCT A.flight_num) AS dt_distinct_flight_num_cnt,
    -- 金额极值与时效
    MAX(A.total_price) AS dt_max_order_amount,
    MIN(IF(A.pay_ok = 1 AND A.ticket_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, A.pay_time, A.ticket_time), NULL)) AS dt_min_pay_ticket_interval_sec,
    MIN(IF(A.refund_apply_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, A.pay_time, A.refund_apply_time), NULL)) AS dt_min_refund_pay_interval_sec,
    AVG(IF(A.refund_complete_time IS NOT NULL AND A.refund_apply_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, A.refund_apply_time, A.refund_complete_time), NULL)) AS dt_avg_refund_complete_interval_sec
FROM flight.dwd_ord_wide_order_di A
LEFT JOIN (
    -- 票维度：p_passenger_name / p_card_num / p_mobile，按 order_no 聚合到订单粒度
    SELECT
        IF(o_dom_inter = 1, o_main_order_no, o_order_no) AS order_no,
        COUNT(DISTINCT p_passenger_name) AS p_passenger_name,
        COUNT(DISTINCT p_card_num) AS p_card_num,
        COUNT(DISTINCT p_mobile) AS p_mobile
    FROM flight.dwd_ord_wide_order_ticket_di
    WHERE dt = '${DATE}'
    GROUP BY IF(o_dom_inter = 1, o_main_order_no, o_order_no)
) T ON T.order_no = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
LEFT JOIN (
    -- 支付工具：cardnumf6l4join 或 thirdUid（来自 pp_pub.dwd_fin_sub_trade_payment_account_detail_di）
    SELECT
        orderid,
        MAX(COALESCE(cardnumf6l4join, regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1))) AS pay_tool_id
    FROM pp_pub.dwd_fin_sub_trade_payment_account_detail_di
    WHERE dt = '${DATE}'
      AND COALESCE(cardnumf6l4join, regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) IS NOT NULL
    GROUP BY orderid
) P ON P.orderid = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
LEFT JOIN (
    -- 退款金额：来自 pp_pub.dwd__qunar_selfpayord_di（先聚合到 orderid 粒度避免笛卡尔积）
    SELECT
        orderid,
        SUM(amt) AS refund_amount
    FROM pp_pub.dwd__qunar_selfpayord_di
    WHERE d = '${DATE}'
      AND order_type_change LIKE '%机票%'
      AND opertype = '退款'
    GROUP BY orderid
) R ON R.orderid = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
WHERE A.dt = '${DATE}'
  AND A.uid IS NOT NULL AND A.uid != ''
GROUP BY A.uid;


-- #####################################################################
-- 2. 酒店设备-日宽表
-- 源：hotel.dwd_ord_order_detail_di
-- 字段严格来自 字段名.xlsx sheet=酒店订单表字段
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dws_device_hotel_daily (
    dt                              DATE,
    device_id                       VARCHAR(64),
    dt_total_order_cnt              BIGINT,
    dt_pay_ok_order_cnt             BIGINT,
    dt_pay_ok_order_amount          DECIMAL(18,2),
    dt_cancel_order_cnt             BIGINT,
    dt_abnormal_cancel_cnt          BIGINT,
    dt_refund_order_cnt             BIGINT,
    -- 担保/后付/钟点房/恶意（is_guarantee/guarantee_amount/is_laterpay/is_hours_room/is_malice）
    dt_guarantee_cnt                BIGINT,
    dt_guarantee_amount_sum         DECIMAL(18,2),
    dt_laterpay_cnt                 BIGINT,
    dt_hourroom_cnt                 BIGINT,
    dt_malice_cnt                   BIGINT,
    -- 缺陷（defect_type）
    dt_defect_cnt                   BIGINT,
    -- 聚集（hotel_seq/city_code/contact_phone/guest_idcard_info）
    dt_distinct_hotel_cnt           BIGINT,
    dt_distinct_city_cnt            BIGINT,
    dt_distinct_contact_mob_cnt     BIGINT,
    dt_distinct_guest_idcard_cnt    BIGINT,
    -- 距离（cancel_distance/user_hotel_distance）
    dt_cancel_distance_avg          DECIMAL(18,2),
    dt_user_hotel_distance_avg      DECIMAL(18,2),
    -- 间夜与早餐（final_room_night/room_night/breakfast）
    dt_room_night_sum               BIGINT,
    dt_breakfast_sum                BIGINT,
    -- 其他标记（is_pre_sale/is_distribute/use_free_cancel/free_cancel_flag/is_singlemember/is_valid/is_scan/actual_success_paymode）
    dt_pre_sale_cnt                 BIGINT,
    dt_distribute_cnt               BIGINT,
    dt_free_cancel_cnt              BIGINT,
    dt_singlemember_cnt             BIGINT,
    dt_invalid_cnt                  BIGINT,
    dt_scan_cnt                     BIGINT,
    dt_actual_success_paymode_cnt   BIGINT,
    -- 金额极值与时效（payamount/pay_time/refund_time）
    dt_max_order_amount             DECIMAL(18,2),
    dt_refund_interval_avg_sec      BIGINT
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


INSERT OVERWRITE leiden.dws_device_hotel_daily PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    device_id,
    COUNT(DISTINCT order_no) AS dt_total_order_cnt,
    COUNT(DISTINCT IF(pay_status = '已支付' OR pay_status = '支付成功', order_no, NULL)) AS dt_pay_ok_order_cnt,
    SUM(CAST(payamount AS DECIMAL(18,2))) AS dt_pay_ok_order_amount,
    COUNT(DISTINCT IF(order_status = '已取消' OR order_status = '订单已取消', order_no, NULL)) AS dt_cancel_order_cnt,
    SUM(IF(abnormal_condition_refund = 1, 1, 0)) AS dt_abnormal_cancel_cnt,
    COUNT(DISTINCT IF(refund_time IS NOT NULL, order_no, NULL)) AS dt_refund_order_cnt,
    -- 担保/后付/钟点房/恶意
    SUM(IF(is_guarantee = 1, 1, 0)) AS dt_guarantee_cnt,
    SUM(CAST(guarantee_amount AS DECIMAL(18,2))) AS dt_guarantee_amount_sum,
    SUM(IF(is_laterpay = 1, 1, 0)) AS dt_laterpay_cnt,
    SUM(IF(is_hours_room = 1, 1, 0)) AS dt_hourroom_cnt,
    SUM(IF(is_malice = 1, 1, 0)) AS dt_malice_cnt,
    -- 缺陷
    COUNT(DISTINCT IF(defect_type IS NOT NULL AND defect_type != '', order_no, NULL)) AS dt_defect_cnt,
    -- 聚集
    COUNT(DISTINCT hotel_seq) AS dt_distinct_hotel_cnt,
    COUNT(DISTINCT city_code) AS dt_distinct_city_cnt,
    COUNT(DISTINCT contact_phone) AS dt_distinct_contact_mob_cnt,
    COUNT(DISTINCT guest_idcard_info) AS dt_distinct_guest_idcard_cnt,
    -- 距离
    AVG(CAST(cancel_distance AS DECIMAL(18,2))) AS dt_cancel_distance_avg,
    AVG(CAST(user_hotel_distance AS DECIMAL(18,2))) AS dt_user_hotel_distance_avg,
    -- 间夜与早餐
    SUM(COALESCE(CAST(final_room_night AS BIGINT), CAST(room_night AS BIGINT))) AS dt_room_night_sum,
    SUM(CAST(breakfast AS BIGINT)) AS dt_breakfast_sum,
    -- 其他标记
    SUM(IF(is_pre_sale = 1, 1, 0)) AS dt_pre_sale_cnt,
    SUM(IF(is_distribute = 1, 1, 0)) AS dt_distribute_cnt,
    SUM(COALESCE(CAST(use_free_cancel AS BIGINT), CAST(free_cancel_flag AS BIGINT))) AS dt_free_cancel_cnt,
    SUM(IF(is_singlemember = 1, 1, 0)) AS dt_singlemember_cnt,
    SUM(IF(is_valid = 0, 1, 0)) AS dt_invalid_cnt,
    SUM(IF(is_scan = 1, 1, 0)) AS dt_scan_cnt,
    COUNT(DISTINCT IF(actual_success_paymode IS NOT NULL AND actual_success_paymode != '', order_no, NULL)) AS dt_actual_success_paymode_cnt,
    -- 金额极值与时效
    MAX(CAST(payamount AS DECIMAL(18,2))) AS dt_max_order_amount,
    CAST(AVG(IF(refund_time IS NOT NULL AND pay_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, pay_time, refund_time), NULL)) AS BIGINT) AS dt_refund_interval_avg_sec
FROM hotel.dwd_ord_order_detail_di
WHERE dt = '${DATE}'
  AND data_source = 'hms'
  AND device_id IS NOT NULL AND device_id != ''
GROUP BY device_id;


-- #####################################################################
-- 3. 门票设备-日宽表
-- 源：ticket.dwd_ord_order_detail_di
-- 字段严格来自 字段名.xlsx sheet=门票-订单表维度字段
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dws_device_ticket_daily (
    dt                              DATE,
    device_id                       VARCHAR(64),
    dt_total_order_cnt              BIGINT,
    dt_pay_ok_order_cnt             BIGINT,
    dt_pay_ok_order_amount          DECIMAL(18,2),
    dt_refund_order_cnt             BIGINT,
    dt_refund_money                 DECIMAL(18,2),
    dt_full_refund_cnt              BIGINT,
    dt_refund_times_cnt             BIGINT,
    dt_auto_refund_fail_cnt         BIGINT,
    dt_supplier_reject_cnt          BIGINT,
    dt_qunar_reject_cnt             BIGINT,
    -- 黄牛/刷票/零元票/一元票（filter_flag/is_zero_product）
    dt_huangniu_cnt                 BIGINT,
    dt_test_cnt                     BIGINT,
    dt_brush_cnt                    BIGINT,
    dt_zero_product_cnt             BIGINT,
    dt_one_yuan_cnt                 BIGINT,
    -- 营销（marketing_cashback_money/marketing_lijian_money/coupon_money/order_red_packet_money/order_subsidy_money/subsidy_money）
    dt_marketing_cashback_sum       DECIMAL(18,2),
    dt_marketing_lijian_sum         DECIMAL(18,2),
    dt_coupon_sum                   DECIMAL(18,2),
    dt_red_packet_sum               DECIMAL(18,2),
    dt_subsidy_sum                  DECIMAL(18,2),
    -- 涨价（increase_income/force_qunar_price_income/order_force_qunar_price_income）
    dt_increase_income_sum          DECIMAL(18,2),
    dt_force_price_sum              DECIMAL(18,2),
    -- 聚集（sight_id/sight_city/goods_id/supplier_id/order_distributor_id/fp/order_contact_mobile）
    dt_distinct_sight_cnt           BIGINT,
    dt_distinct_sight_city_cnt      BIGINT,
    dt_distinct_goods_cnt           BIGINT,
    dt_distinct_supplier_cnt        BIGINT,
    dt_distinct_distributor_cnt     BIGINT,
    dt_distinct_fp_cnt              BIGINT,
    dt_distinct_mobile_cnt          BIGINT,
    -- 规模（hcount）
    dt_hcount_sum                   BIGINT,
    -- 时效（issue_speed/order_takeoff_date/order_pay_time/order_refund_times）
    dt_issue_speed_avg              DECIMAL(18,2),
    dt_takeoff_pay_interval_avg_sec BIGINT,
    dt_refund_pay_interval_avg_sec  BIGINT,
    -- 异地（local_city/sight_city）
    dt_local_not_match_cnt          BIGINT,
    -- 大包/营销/自营/B2B（if_dabao/order_is_marketing_ticket/order_self_operate/order_sale_type）
    dt_dabao_cnt                    BIGINT,
    dt_marketing_ticket_cnt         BIGINT,
    dt_self_operate_cnt             BIGINT,
    dt_b2b_cnt                      BIGINT,
    -- 金额极值（money）
    dt_max_order_amount             DECIMAL(18,2)
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


INSERT OVERWRITE leiden.dws_device_ticket_daily PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    trace_uid AS device_id,
    COUNT(DISTINCT order_id) AS dt_total_order_cnt,
    COUNT(DISTINCT IF(op_type = 'pay' OR order_status IN (26, 33, 34), order_id, NULL)) AS dt_pay_ok_order_cnt,
    SUM(pay_money) AS dt_pay_ok_order_amount,
    COUNT(DISTINCT IF(op_type = 'refund' OR order_refund_status IN (27, 36, 22), order_id, NULL)) AS dt_refund_order_cnt,
    SUM(refund_money) AS dt_refund_money,
    SUM(IF(is_full_refund = 1, 1, 0)) AS dt_full_refund_cnt,
    COUNT(DISTINCT IF(order_refund_times IS NOT NULL, order_id, NULL)) AS dt_refund_times_cnt,
    SUM(IF(order_refund_status = 21, 1, 0)) AS dt_auto_refund_fail_cnt,
    SUM(IF(order_refund_status = 24, 1, 0)) AS dt_supplier_reject_cnt,
    SUM(IF(order_refund_status = 26, 1, 0)) AS dt_qunar_reject_cnt,
    -- 黄牛/刷票/零元票/一元票
    SUM(IF(filter_flag = 2, 1, 0)) AS dt_huangniu_cnt,
    SUM(IF(filter_flag = 1, 1, 0)) AS dt_test_cnt,
    SUM(IF(filter_flag = 9, 1, 0)) AS dt_brush_cnt,
    SUM(IF(is_zero_product = 1, 1, 0)) AS dt_zero_product_cnt,
    SUM(IF(filter_flag = 5, 1, 0)) AS dt_one_yuan_cnt,
    -- 营销
    SUM(marketing_cashback_money) AS dt_marketing_cashback_sum,
    SUM(marketing_lijian_money) AS dt_marketing_lijian_sum,
    SUM(coupon_money) AS dt_coupon_sum,
    SUM(order_red_packet_money) AS dt_red_packet_sum,
    SUM(COALESCE(order_subsidy_money, subsidy_money)) AS dt_subsidy_sum,
    -- 涨价
    SUM(increase_income) AS dt_increase_income_sum,
    SUM(COALESCE(force_qunar_price_income, order_force_qunar_price_income)) AS dt_force_price_sum,
    -- 聚集
    COUNT(DISTINCT sight_id) AS dt_distinct_sight_cnt,
    COUNT(DISTINCT sight_city) AS dt_distinct_sight_city_cnt,
    COUNT(DISTINCT goods_id) AS dt_distinct_goods_cnt,
    COUNT(DISTINCT supplier_id) AS dt_distinct_supplier_cnt,
    COUNT(DISTINCT order_distributor_id) AS dt_distinct_distributor_cnt,
    COUNT(DISTINCT fp) AS dt_distinct_fp_cnt,
    COUNT(DISTINCT order_contact_mobile) AS dt_distinct_mobile_cnt,
    -- 规模
    SUM(CAST(hcount AS BIGINT)) AS dt_hcount_sum,
    -- 时效
    AVG(CAST(issue_speed AS DECIMAL(18,2))) AS dt_issue_speed_avg,
    CAST(AVG(IF(order_takeoff_date IS NOT NULL AND order_pay_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, order_pay_time, CAST(order_takeoff_date AS DATETIME)), NULL)) AS BIGINT) AS dt_takeoff_pay_interval_avg_sec,
    CAST(AVG(IF(order_refund_times IS NOT NULL AND order_pay_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, order_pay_time, order_refund_times), NULL)) AS BIGINT) AS dt_refund_pay_interval_avg_sec,
    -- 异地
    SUM(IF(local_city IS NOT NULL AND sight_city IS NOT NULL AND local_city != sight_city, 1, 0)) AS dt_local_not_match_cnt,
    -- 大包/营销/自营/B2B
    SUM(IF(if_dabao = 1, 1, 0)) AS dt_dabao_cnt,
    SUM(IF(order_is_marketing_ticket = 1, 1, 0)) AS dt_marketing_ticket_cnt,
    SUM(IF(order_self_operate = 1, 1, 0)) AS dt_self_operate_cnt,
    SUM(IF(order_sale_type = 1, 1, 0)) AS dt_b2b_cnt,
    -- 金额极值
    MAX(money) AS dt_max_order_amount
FROM ticket.dwd_ord_order_detail_di
WHERE dt = '${DATE}'
  AND trace_uid IS NOT NULL AND trace_uid != ''
GROUP BY trace_uid;


-- #####################################################################
-- 4. 设备-支付退款日宽表
-- 源：pp_pub.dwd__qunar_selfpayord_di
-- 字段：d/amt/brand_id/brand_name/opertype/order_type_change/paymenttype/is_self/merchantid/merchantname/post_flag/extdata
-- extdata 展开字段：last_brand_id/cashier_type/new_post_flag/busi_order_no/promotion_investor/card_cnt/default_paymentway_id/user_id/platform/order_type/promotion_id/last_paycategory/card_orgnz
-- 关联：orderid → 各业务线订单表 order_no → device_id
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dws_device_pay_refund_daily (
    dt                          DATE,
    device_id                   VARCHAR(64),
    biz_line                    VARCHAR(32),
    dt_pay_cnt                  BIGINT,
    dt_pay_amt_sum              DECIMAL(18,2),
    dt_refund_cnt               BIGINT,
    dt_refund_amt_sum           DECIMAL(18,2),
    dt_distinct_brand_id_cnt    BIGINT,
    dt_distinct_brand_name_cnt  BIGINT,
    dt_distinct_merchantid_cnt  BIGINT,
    dt_distinct_merchantname_cnt BIGINT,
    dt_distinct_paymenttype_cnt BIGINT,
    dt_distinct_card_cnt        BIGINT,
    dt_card_cnt_avg             DECIMAL(18,2),
    dt_card_cnt_max             BIGINT,
    dt_distinct_card_orgnz_cnt  BIGINT,
    dt_distinct_last_brand_id_cnt BIGINT,
    dt_distinct_last_paycategory_cnt BIGINT,
    dt_distinct_default_paymentway_cnt BIGINT,
    dt_distinct_promotion_id_cnt BIGINT,
    dt_distinct_promotion_investor_cnt BIGINT,
    dt_distinct_cashier_type_cnt BIGINT,
    dt_distinct_post_flag_cnt   BIGINT,
    dt_distinct_new_post_flag_cnt BIGINT,
    dt_distinct_platform_cnt    BIGINT,
    dt_self_refund_cnt          BIGINT,
    dt_same_day_refund_cnt      BIGINT
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id, biz_line)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


INSERT OVERWRITE leiden.dws_device_pay_refund_daily PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    D.device_id,
    P.order_type_change AS biz_line,
    COUNT(DISTINCT IF(P.opertype = '扣款', P.orderid, NULL)) AS dt_pay_cnt,
    SUM(IF(P.opertype = '扣款', P.amt, 0)) AS dt_pay_amt_sum,
    COUNT(DISTINCT IF(P.opertype = '退款', P.orderid, NULL)) AS dt_refund_cnt,
    SUM(IF(P.opertype = '退款', P.amt, 0)) AS dt_refund_amt_sum,
    COUNT(DISTINCT P.brand_id) AS dt_distinct_brand_id_cnt,
    COUNT(DISTINCT P.brand_name) AS dt_distinct_brand_name_cnt,
    COUNT(DISTINCT P.merchantid) AS dt_distinct_merchantid_cnt,
    COUNT(DISTINCT P.merchantname) AS dt_distinct_merchantname_cnt,
    COUNT(DISTINCT P.paymenttype) AS dt_distinct_paymenttype_cnt,
    COUNT(DISTINCT P.card_cnt) AS dt_distinct_card_cnt,
    AVG(P.card_cnt) AS dt_card_cnt_avg,
    MAX(P.card_cnt) AS dt_card_cnt_max,
    COUNT(DISTINCT P.card_orgnz) AS dt_distinct_card_orgnz_cnt,
    COUNT(DISTINCT P.last_brand_id) AS dt_distinct_last_brand_id_cnt,
    COUNT(DISTINCT P.last_paycategory) AS dt_distinct_last_paycategory_cnt,
    COUNT(DISTINCT P.default_paymentway_id) AS dt_distinct_default_paymentway_cnt,
    COUNT(DISTINCT P.promotion_id) AS dt_distinct_promotion_id_cnt,
    COUNT(DISTINCT P.promotion_investor) AS dt_distinct_promotion_investor_cnt,
    COUNT(DISTINCT P.cashier_type) AS dt_distinct_cashier_type_cnt,
    COUNT(DISTINCT P.post_flag) AS dt_distinct_post_flag_cnt,
    COUNT(DISTINCT P.new_post_flag) AS dt_distinct_new_post_flag_cnt,
    COUNT(DISTINCT P.platform) AS dt_distinct_platform_cnt,
    SUM(IF(P.opertype = '退款' AND P.is_self = '1', 1, 0)) AS dt_self_refund_cnt,
    SUM(IF(P.opertype = '退款', 1, 0)) AS dt_same_day_refund_cnt
FROM (
    -- 支付退款表 extdata 展开（严格按用户提供的 SQL）
    SELECT
        d AS dt,
        orderid,
        amt,
        brand_id,
        brand_name,
        opertype,
        order_type_change,
        order_type_name,
        paymenttype,
        is_self,
        merchantid,
        merchantname,
        post_flag,
        extdata['last_brand_id'] AS last_brand_id,
        extdata['cashier_type'] AS cashier_type,
        extdata['new_post_flag'] AS new_post_flag,
        extdata['busi_order_no'] AS busi_order_no,
        extdata['promotion_investor'] AS promotion_investor,
        CAST(extdata['card_cnt'] AS BIGINT) AS card_cnt,
        extdata['default_paymentway_id'] AS default_paymentway_id,
        extdata['user_id'] AS pay_user_id,
        extdata['platform'] AS platform,
        extdata['order_type'] AS pay_order_type,
        extdata['promotion_id'] AS promotion_id,
        extdata['last_paycategory'] AS last_paycategory,
        extdata['card_orgnz'] AS card_orgnz
    FROM pp_pub.dwd__qunar_selfpayord_di
    WHERE d = '${DATE}'
) P
LEFT JOIN (
    -- 通过 orderid 反查各业务线订单表取 device_id
    SELECT IF(dom_inter = 1, main_order_no, order_no) AS order_no, uid AS device_id, '机票' AS biz_line
    FROM flight.dwd_ord_wide_order_di
    WHERE dt = '${DATE}' AND uid IS NOT NULL AND uid != ''
    UNION ALL
    SELECT order_no, device_id, '酒店' AS biz_line
    FROM hotel.dwd_ord_order_detail_di
    WHERE dt = '${DATE}' AND data_source = 'hms' AND device_id IS NOT NULL AND device_id != ''
    UNION ALL
    SELECT order_id AS order_no, trace_uid AS device_id, '门票' AS biz_line
    FROM ticket.dwd_ord_order_detail_di
    WHERE dt = '${DATE}' AND trace_uid IS NOT NULL AND trace_uid != ''
) D ON D.order_no = P.orderid
WHERE D.device_id IS NOT NULL
GROUP BY D.device_id, P.order_type_change;


-- #####################################################################
-- 5. 设备-工单日宽表
-- 源：default.ods_callcenterdb_workorder_detail
-- 字段：flow_log_id/flow_no/order_no/biz_line/content_type/channel_way/log_type/
--      problem_names_before/problem_names_after/status_before/status_after/
--      close_type/close_solution_type_id/manager_id_after/lock_id_after/create_id/create_name/
--      group_id/workplace_id/ce_need_reply/del/create_time
-- 关联：order_no → 各业务线订单表 → device_id
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dws_device_workorder_daily (
    dt                          DATE,
    device_id                   VARCHAR(64),
    biz_line                    VARCHAR(32),
    dt_workorder_cnt            BIGINT,
    dt_distinct_flow_no_cnt     BIGINT,
    dt_chat_cnt                 BIGINT,
    dt_phone_cnt                BIGINT,
    dt_auto_channel_cnt         BIGINT,
    dt_manual_channel_cnt       BIGINT,
    dt_node_change_cnt          BIGINT,
    dt_manager_change_cnt       BIGINT,
    dt_lock_change_cnt          BIGINT,
    dt_reopen_cnt               BIGINT,
    dt_problem_type_cnt         BIGINT,
    dt_close_solution_type_cnt  BIGINT,
    dt_close_type_cnt           BIGINT,
    dt_del_cnt                  BIGINT,
    dt_ce_need_reply_cnt        BIGINT,
    dt_distinct_create_id_cnt   BIGINT,
    dt_distinct_workplace_cnt   BIGINT,
    dt_distinct_group_cnt       BIGINT,
    dt_log_type_cnt             BIGINT,
    dt_no_order_workorder_cnt   BIGINT,
    dt_refund_type_workorder_cnt BIGINT,
    dt_compensation_type_workorder_cnt BIGINT
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id, biz_line)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


INSERT OVERWRITE leiden.dws_device_workorder_daily PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    D.device_id,
    W.biz_line,
    COUNT(DISTINCT W.flow_log_id) AS dt_workorder_cnt,
    COUNT(DISTINCT W.flow_no) AS dt_distinct_flow_no_cnt,
    SUM(IF(W.content_type = 'CHAT', 1, 0)) AS dt_chat_cnt,
    SUM(IF(W.content_type = 'PHONE', 1, 0)) AS dt_phone_cnt,
    SUM(IF(W.channel_way = 'AUTO', 1, 0)) AS dt_auto_channel_cnt,
    SUM(IF(W.channel_way = 'MANUAL', 1, 0)) AS dt_manual_channel_cnt,
    COUNT(DISTINCT W.node_id_after) AS dt_node_change_cnt,
    COUNT(DISTINCT W.manager_id_after) AS dt_manager_change_cnt,
    COUNT(DISTINCT W.lock_id_after) AS dt_lock_change_cnt,
    SUM(IF(W.status_before IS NOT NULL AND W.status_after IS NOT NULL
           AND W.status_before != W.status_after, 1, 0)) AS dt_reopen_cnt,
    -- StarRocks 没有 flatten，用 split + array_distinct 近似
    COUNT(DISTINCT W.problem_names_after) AS dt_problem_type_cnt,
    COUNT(DISTINCT W.close_solution_type_id) AS dt_close_solution_type_cnt,
    COUNT(DISTINCT W.close_type) AS dt_close_type_cnt,
    SUM(IF(W.del = 1, 1, 0)) AS dt_del_cnt,
    SUM(IF(W.ce_need_reply = 1, 1, 0)) AS dt_ce_need_reply_cnt,
    COUNT(DISTINCT W.create_id) AS dt_distinct_create_id_cnt,
    COUNT(DISTINCT W.workplace_id) AS dt_distinct_workplace_cnt,
    COUNT(DISTINCT W.group_id) AS dt_distinct_group_cnt,
    COUNT(DISTINCT W.log_type) AS dt_log_type_cnt,
    SUM(IF(W.order_no IS NULL OR W.order_no = '', 1, 0)) AS dt_no_order_workorder_cnt,
    SUM(IF(W.problem_names_after LIKE '%退款%', 1, 0)) AS dt_refund_type_workorder_cnt,
    SUM(IF(W.problem_names_after LIKE '%赔付%' OR W.problem_names_after LIKE '%补偿%', 1, 0)) AS dt_compensation_type_workorder_cnt
FROM default.ods_callcenterdb_workorder_detail W
LEFT JOIN (
    SELECT IF(dom_inter = 1, main_order_no, order_no) AS order_no, uid AS device_id, '机票' AS biz_line
    FROM flight.dwd_ord_wide_order_di
    WHERE dt = '${DATE}' AND uid IS NOT NULL AND uid != ''
    UNION ALL
    SELECT order_no, device_id, '酒店' AS biz_line
    FROM hotel.dwd_ord_order_detail_di
    WHERE dt = '${DATE}' AND data_source = 'hms' AND device_id IS NOT NULL AND device_id != ''
    UNION ALL
    SELECT order_id AS order_no, trace_uid AS device_id, '门票' AS biz_line
    FROM ticket.dwd_ord_order_detail_di
    WHERE dt = '${DATE}' AND trace_uid IS NOT NULL AND trace_uid != ''
) D ON D.order_no = W.order_no
WHERE W.dt = '${DATE}'
  AND D.device_id IS NOT NULL
GROUP BY D.device_id, W.biz_line;


-- #####################################################################
-- 6. 设备-客诉赔付日宽表（关联 comp，不修改 comp 原始查询）
-- 源：default.ods_callcenterdb_cc_compensation
-- comp 字段来自用户首条 SQL：order_no/problem_name/problem_id/solution/responser/responser_secondary/
--   detail_reason/biz_type/compensation_status/compensation_amount/consume_amount/refund_amount/
--   other_amount/total_amount/audit_result/reject_back/compensation_way/auto_pay/flow_no/create_time/update_time
-- 关联：comp.order_no → 各业务线订单表 → device_id
-- 金额口径：仅 compensation_status = 'pay_success'
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dws_device_compensation_daily (
    dt                                  DATE,
    device_id                           VARCHAR(64),
    biz_line                            VARCHAR(32),
    -- G2.1 规模
    dt_compensation_order_cnt           BIGINT,
    dt_compensation_cnt                 BIGINT,
    dt_compensation_amount              DECIMAL(18,2),
    dt_refund_amount                    DECIMAL(18,2),
    dt_consume_amount                   DECIMAL(18,2),
    dt_other_amount                     DECIMAL(18,2),
    dt_total_compensation_amount        DECIMAL(18,2),
    -- G2.3 状态与审核
    dt_compensation_pay_success_cnt     BIGINT,
    dt_compensation_pending_cnt         BIGINT,
    dt_compensation_audit_pass_cnt      BIGINT,
    dt_compensation_reject_cnt          BIGINT,
    dt_compensation_reject_back_type_cnt BIGINT,
    dt_compensation_auto_pay_cnt        BIGINT,
    -- G2.4 时效
    dt_compensation_create_to_pay_interval_avg_sec BIGINT,
    dt_compensation_create_to_pay_interval_min_sec BIGINT,
    dt_compensation_update_interval_avg_sec BIGINT,
    dt_compensation_same_day_pay_cnt    BIGINT,
    dt_order_to_compensation_interval_avg_sec BIGINT,
    dt_order_to_compensation_interval_min_sec BIGINT,
    -- G2.5 原因与责任
    dt_distinct_problem_name_cnt        BIGINT,
    dt_distinct_problem_id_cnt          BIGINT,
    dt_distinct_solution_cnt            BIGINT,
    dt_distinct_detail_reason_cnt       BIGINT,
    dt_distinct_responser_cnt           BIGINT,
    dt_distinct_responser_secondary_cnt BIGINT,
    dt_distinct_compensation_way_cnt    BIGINT,
    -- G2.6 金额分布
    dt_compensation_amount_avg          DECIMAL(18,2),
    dt_compensation_amount_max          DECIMAL(18,2),
    dt_high_compensation_cnt            BIGINT
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id, biz_line)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


INSERT OVERWRITE leiden.dws_device_compensation_daily PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    D.device_id,
    C.biz_line,
    -- G2.1 规模
    COUNT(DISTINCT C.order_no) AS dt_compensation_order_cnt,
    COUNT(DISTINCT C.flow_no) AS dt_compensation_cnt,
    ROUND(SUM(IF(C.compensation_status = 'pay_success', C.compensation_amount, 0)), 2) AS dt_compensation_amount,
    ROUND(SUM(IF(C.compensation_status = 'pay_success', C.refund_amount, 0)), 2) AS dt_refund_amount,
    ROUND(SUM(IF(C.compensation_status = 'pay_success', C.consume_amount, 0)), 2) AS dt_consume_amount,
    ROUND(SUM(IF(C.compensation_status = 'pay_success', C.other_amount, 0)), 2) AS dt_other_amount,
    ROUND(SUM(IF(C.compensation_status = 'pay_success', C.total_amount, 0)), 2) AS dt_total_compensation_amount,
    -- G2.3 状态与审核
    COUNT(DISTINCT IF(C.compensation_status = 'pay_success', C.flow_no, NULL)) AS dt_compensation_pay_success_cnt,
    COUNT(DISTINCT IF(C.compensation_status NOT IN ('pay_success','rejected','closed') AND C.compensation_status IS NOT NULL, C.flow_no, NULL)) AS dt_compensation_pending_cnt,
    COUNT(DISTINCT IF(C.audit_result = 'pass' OR C.audit_result = '通过', C.flow_no, NULL)) AS dt_compensation_audit_pass_cnt,
    COUNT(DISTINCT IF(C.reject_back IS NOT NULL AND C.reject_back != '', C.flow_no, NULL)) AS dt_compensation_reject_cnt,
    COUNT(DISTINCT C.reject_back) AS dt_compensation_reject_back_type_cnt,
    COUNT(DISTINCT IF(C.auto_pay = '1' OR C.auto_pay = 'true', C.flow_no, NULL)) AS dt_compensation_auto_pay_cnt,
    -- G2.4 时效
    CAST(AVG(IF(C.compensation_status = 'pay_success' AND C.update_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, C.create_time, C.update_time), NULL)) AS BIGINT) AS dt_compensation_create_to_pay_interval_avg_sec,
    CAST(MIN(IF(C.compensation_status = 'pay_success' AND C.update_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, C.create_time, C.update_time), NULL)) AS BIGINT) AS dt_compensation_create_to_pay_interval_min_sec,
    CAST(AVG(IF(C.update_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, C.create_time, C.update_time), NULL)) AS BIGINT) AS dt_compensation_update_interval_avg_sec,
    COUNT(DISTINCT IF(C.compensation_status = 'pay_success'
        AND DATE(C.create_time) = DATE(C.update_time), C.flow_no, NULL)) AS dt_compensation_same_day_pay_cnt,
    CAST(AVG(IF(D.order_create_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, D.order_create_time, C.create_time), NULL)) AS BIGINT) AS dt_order_to_compensation_interval_avg_sec,
    CAST(MIN(IF(D.order_create_time IS NOT NULL,
        TIMESTAMPDIFF(SECOND, D.order_create_time, C.create_time), NULL)) AS BIGINT) AS dt_order_to_compensation_interval_min_sec,
    -- G2.5 原因与责任
    COUNT(DISTINCT C.problem_name) AS dt_distinct_problem_name_cnt,
    COUNT(DISTINCT C.problem_id) AS dt_distinct_problem_id_cnt,
    COUNT(DISTINCT C.solution) AS dt_distinct_solution_cnt,
    COUNT(DISTINCT C.detail_reason) AS dt_distinct_detail_reason_cnt,
    COUNT(DISTINCT C.responser) AS dt_distinct_responser_cnt,
    COUNT(DISTINCT C.responser_secondary) AS dt_distinct_responser_secondary_cnt,
    COUNT(DISTINCT C.compensation_way) AS dt_distinct_compensation_way_cnt,
    -- G2.6 金额分布
    ROUND(AVG(IF(C.compensation_status = 'pay_success', C.total_amount, NULL)), 2) AS dt_compensation_amount_avg,
    ROUND(MAX(IF(C.compensation_status = 'pay_success', C.total_amount, NULL)), 2) AS dt_compensation_amount_max,
    COUNT(DISTINCT IF(C.total_amount > 500, C.flow_no, NULL)) AS dt_high_compensation_cnt
FROM (
    -- comp 表保持原样，不修改，仅做分区过滤 + 原始字段透传
    SELECT
        dt,
        order_no,
        flow_no,
        create_time,
        update_time,
        problem_name,
        problem_id,
        solution,
        detail_reason,
        responser,
        responser_secondary,
        compensation_status,
        compensation_amount,
        consume_amount,
        refund_amount,
        other_amount,
        total_amount,
        audit_result,
        reject_back,
        compensation_way,
        auto_pay,
        biz_type,
        biz_line
    FROM default.ods_callcenterdb_cc_compensation
    WHERE dt = '${DATE}'
      AND create_time >= '2026-01-01'
) C
LEFT JOIN (
    -- 通过 order_no 反查各业务线订单取 device_id + 订单创建时间
    SELECT IF(dom_inter = 1, main_order_no, order_no) AS order_no, uid AS device_id, '机票' AS biz_line, create_time AS order_create_time
    FROM flight.dwd_ord_wide_order_di
    WHERE dt = '${DATE}' AND uid IS NOT NULL AND uid != ''
    UNION ALL
    SELECT order_no, device_id, '酒店' AS biz_line, order_time AS order_create_time
    FROM hotel.dwd_ord_order_detail_di
    WHERE dt = '${DATE}' AND data_source = 'hms' AND device_id IS NOT NULL AND device_id != ''
    UNION ALL
    SELECT order_id AS order_no, trace_uid AS device_id, '门票' AS biz_line, order_create_time
    FROM ticket.dwd_ord_order_detail_di
    WHERE dt = '${DATE}' AND trace_uid IS NOT NULL AND trace_uid != ''
) D ON D.order_no = C.order_no
WHERE D.device_id IS NOT NULL
  -- comp.biz_line 字段存在但可能为空，优先用 D.biz_line，此处保留 C.biz_line 透传
GROUP BY D.device_id, C.biz_line;


-- #####################################################################
-- 7. 设备-跨业务线汇总宽表（含 comp 跨业务线赔付）
-- 聚合：dws_device_flight_daily + dws_device_hotel_daily + dws_device_ticket_daily
--      + dws_device_compensation_daily（comp 关联）
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.dws_device_cross_biz_daily (
    dt                              DATE,
    device_id                       VARCHAR(64),
    dt_cross_order_cnt              BIGINT,
    dt_cross_biz_cnt                BIGINT,
    dt_cross_pay_ok_amount          DECIMAL(18,2),
    dt_cross_refund_amount          DECIMAL(18,2),
    dt_cross_distinct_user_cnt      BIGINT,
    dt_cross_distinct_mobile_cnt    BIGINT,
    dt_cross_distinct_pay_tool_cnt  BIGINT,
    dt_cross_distinct_ip_cnt        BIGINT,
    dt_cross_distinct_passenger_cnt BIGINT,
    dt_cross_scalper_cnt            BIGINT,
    dt_cross_malice_cnt             BIGINT,
    dt_cross_huangniu_cnt           BIGINT,
    -- comp 跨业务线赔付
    dt_cross_compensation_cnt       BIGINT,
    dt_cross_compensation_amount    DECIMAL(18,2),
    dt_cross_compensation_biz_cnt   BIGINT,
    dt_cross_compensation_rate      DECIMAL(6,4)
) ENGINE=OLAP
DUPLICATE KEY(dt, device_id)
PARTITION BY (dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


INSERT OVERWRITE leiden.dws_device_cross_biz_daily PARTITION(dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS dt,
    U.device_id,
    SUM(U.dt_total_order_cnt) AS dt_cross_order_cnt,
    COUNT(DISTINCT U.biz_line) AS dt_cross_biz_cnt,
    SUM(U.dt_pay_ok_order_amount) AS dt_cross_pay_ok_amount,
    SUM(U.dt_refund_amount) AS dt_cross_refund_amount,
    SUM(U.dt_distinct_user_id_cnt) AS dt_cross_distinct_user_cnt,
    SUM(U.dt_distinct_mobile_cnt) AS dt_cross_distinct_mobile_cnt,
    SUM(U.dt_distinct_pay_tool_cnt) AS dt_cross_distinct_pay_tool_cnt,
    SUM(U.dt_distinct_ip_cnt) AS dt_cross_distinct_ip_cnt,
    SUM(U.dt_distinct_passenger_cnt) AS dt_cross_distinct_passenger_cnt,
    SUM(U.dt_scalper_cnt) AS dt_cross_scalper_cnt,
    SUM(U.dt_malice_cnt) AS dt_cross_malice_cnt,
    SUM(U.dt_huangniu_cnt) AS dt_cross_huangniu_cnt,
    -- comp 跨业务线赔付
    COALESCE(SUM(C.dt_compensation_order_cnt), 0) AS dt_cross_compensation_cnt,
    COALESCE(SUM(C.dt_total_compensation_amount), 0) AS dt_cross_compensation_amount,
    COUNT(DISTINCT C.biz_line) AS dt_cross_compensation_biz_cnt,
    CASE WHEN SUM(U.dt_total_order_cnt) > 0
         THEN COALESCE(SUM(C.dt_compensation_order_cnt), 0) / SUM(U.dt_total_order_cnt)
         ELSE 0 END AS dt_cross_compensation_rate
FROM (
    -- 机票
    SELECT
        device_id, '机票' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, dt_refund_amount,
        dt_distinct_user_id_cnt, dt_distinct_mobile_cnt, dt_distinct_pay_tool_cnt,
        dt_distinct_ip_cnt, dt_distinct_passenger_cnt,
        dt_scalper_cnt, 0 AS dt_malice_cnt, 0 AS dt_huangniu_cnt
    FROM leiden.dws_device_flight_daily
    WHERE dt = '${DATE}'
    UNION ALL
    -- 酒店
    SELECT
        device_id, '酒店' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, 0 AS dt_refund_amount,
        0 AS dt_distinct_user_id_cnt, dt_distinct_contact_mob_cnt AS dt_distinct_mobile_cnt,
        0 AS dt_distinct_pay_tool_cnt, 0 AS dt_distinct_ip_cnt, dt_distinct_guest_idcard_cnt AS dt_distinct_passenger_cnt,
        0 AS dt_scalper_cnt, dt_malice_cnt, 0 AS dt_huangniu_cnt
    FROM leiden.dws_device_hotel_daily
    WHERE dt = '${DATE}'
    UNION ALL
    -- 门票
    SELECT
        device_id, '门票' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, dt_refund_money AS dt_refund_amount,
        0 AS dt_distinct_user_id_cnt, dt_distinct_mobile_cnt, 0 AS dt_distinct_pay_tool_cnt,
        0 AS dt_distinct_ip_cnt, 0 AS dt_distinct_passenger_cnt,
        0 AS dt_scalper_cnt, 0 AS dt_malice_cnt, dt_huangniu_cnt
    FROM leiden.dws_device_ticket_daily
    WHERE dt = '${DATE}'
) U
LEFT JOIN (
    SELECT
        device_id, biz_line,
        dt_compensation_order_cnt, dt_total_compensation_amount
    FROM leiden.dws_device_compensation_daily
    WHERE dt = '${DATE}'
) C ON C.device_id = U.device_id AND C.biz_line = U.biz_line
GROUP BY U.device_id;


-- #####################################################################
-- 8. 设备号风险特征表（30d 滚动窗口，最终特征表）
-- 联合：dws_device_flight_daily + dws_device_hotel_daily + dws_device_ticket_daily
--      + dws_device_compensation_daily（comp 关联）
-- #####################################################################
CREATE TABLE IF NOT EXISTS leiden.feature_device_risk_profile (
    snapshot_dt                         DATE,
    device_id                           VARCHAR(64),
    -- 规模
    dt_order_cnt_7d                     BIGINT,
    dt_order_cnt_30d                    BIGINT,
    dt_pay_ok_amount_30d                DECIMAL(18,2),
    -- 跨账号聚集
    dt_distinct_user_cnt_30d            BIGINT,
    dt_max_user_per_day_30d             BIGINT,
    dt_distinct_mobile_cnt_30d          BIGINT,
    dt_distinct_email_cnt_30d           BIGINT,
    -- 风险率
    dt_refund_rate_30d                  DECIMAL(6,4),
    dt_refund_amount_rate_30d           DECIMAL(6,4),
    dt_cancel_rate_30d                  DECIMAL(6,4),
    dt_compensation_rate_30d            DECIMAL(6,4),
    dt_compensation_amount_rate_30d     DECIMAL(6,4),
    -- 身份聚集
    dt_distinct_pay_tool_cnt_30d        BIGINT,
    dt_distinct_ip_cnt_30d              BIGINT,
    dt_distinct_contact_mob_cnt_30d     BIGINT,
    dt_distinct_passenger_cnt_30d       BIGINT,
    dt_distinct_passenger_card_cnt_30d  BIGINT,
    -- 业务特有标记
    dt_scalper_cnt_30d                  BIGINT,
    dt_malice_cnt_30d                   BIGINT,
    dt_huangniu_cnt_30d                 BIGINT,
    dt_brush_cnt_30d                    BIGINT,
    dt_zero_product_cnt_30d             BIGINT,
    dt_intercept_cnt_30d                BIGINT,
    dt_abnormal_cancel_cnt_30d          BIGINT,
    dt_full_refund_cnt_30d              BIGINT,
    -- 金额
    dt_voucher_sum_30d                  DECIMAL(18,2),
    dt_coupon_sum_30d                   DECIMAL(18,2),
    dt_marketing_cashback_sum_30d       DECIMAL(18,2),
    dt_subsidy_sum_30d                  DECIMAL(18,2),
    dt_max_order_amount_30d             DECIMAL(18,2),
    -- 时间
    dt_night_order_cnt_30d              BIGINT,
    dt_min_refund_interval_sec_30d      BIGINT,
    -- 工单
    dt_workorder_cnt_30d                BIGINT,
    dt_workorder_reopen_cnt_30d         BIGINT,
    dt_workorder_refund_type_cnt_30d    BIGINT,
    dt_workorder_compensation_type_cnt_30d BIGINT,
    -- G2 赔付（关联 comp 30d 窗口）
    dt_compensation_order_cnt_30d       BIGINT,
    dt_compensation_cnt_30d             BIGINT,
    dt_compensation_amount_30d          DECIMAL(18,2),
    dt_refund_amount_comp_30d           DECIMAL(18,2),
    dt_consume_amount_30d               DECIMAL(18,2),
    dt_total_compensation_amount_30d    DECIMAL(18,2),
    dt_compensation_per_order_30d       DECIMAL(18,2),
    dt_compensation_pay_success_cnt_30d BIGINT,
    dt_compensation_reject_cnt_30d      BIGINT,
    dt_compensation_reject_rate_30d     DECIMAL(6,4),
    dt_compensation_auto_pay_cnt_30d    BIGINT,
    dt_compensation_auto_pay_rate_30d   DECIMAL(6,4),
    dt_compensation_create_to_pay_min_sec_30d BIGINT,
    dt_order_to_compensation_min_sec_30d BIGINT,
    dt_compensation_same_day_pay_cnt_30d BIGINT,
    dt_distinct_problem_name_cnt_30d    BIGINT,
    dt_distinct_detail_reason_cnt_30d   BIGINT,
    dt_distinct_responser_cnt_30d       BIGINT,
    dt_distinct_compensation_way_cnt_30d BIGINT,
    dt_compensation_amount_avg_30d      DECIMAL(18,2),
    dt_compensation_amount_max_30d      DECIMAL(18,2),
    dt_high_compensation_cnt_30d        BIGINT,
    -- 跨业务线
    dt_cross_biz_cnt_30d                BIGINT,
    dt_cross_biz_order_cnt_30d          BIGINT,
    dt_cross_biz_compensation_cnt_30d   BIGINT,
    dt_cross_biz_compensation_amount_30d DECIMAL(18,2),
    dt_cross_biz_compensation_biz_cnt_30d BIGINT
) ENGINE=OLAP
DUPLICATE KEY(snapshot_dt, device_id)
PARTITION BY (snapshot_dt)
DISTRIBUTED BY HASH(device_id) BUCKETS 32
PROPERTIES("replication_num" = "3");


-- 30d 窗口特征 SQL（以机票+酒店+门票 UNION 后 30d 滚动聚合，LEFT JOIN comp 赔付）
INSERT OVERWRITE leiden.feature_device_risk_profile PARTITION(snapshot_dt='${DATE}')
SELECT
    CAST('${DATE}' AS DATE) AS snapshot_dt,
    U.device_id,
    -- 规模 7d/30d
    SUM(IF(U.dt >= DATE_SUB(CAST('${DATE}' AS DATE), 6), U.dt_total_order_cnt, 0)) AS dt_order_cnt_7d,
    SUM(U.dt_total_order_cnt) AS dt_order_cnt_30d,
    SUM(U.dt_pay_ok_order_amount) AS dt_pay_ok_amount_30d,
    -- 跨账号聚集
    SUM(U.dt_distinct_user_id_cnt) AS dt_distinct_user_cnt_30d,
    MAX(U.dt_distinct_user_id_cnt) AS dt_max_user_per_day_30d,
    SUM(U.dt_distinct_mobile_cnt) AS dt_distinct_mobile_cnt_30d,
    SUM(U.dt_distinct_email_cnt) AS dt_distinct_email_cnt_30d,
    -- 风险率
    CASE WHEN SUM(U.dt_total_order_cnt) > 0
         THEN SUM(U.dt_refund_order_cnt) / SUM(U.dt_total_order_cnt)
         ELSE 0 END AS dt_refund_rate_30d,
    CASE WHEN SUM(U.dt_pay_ok_order_amount) > 0
         THEN SUM(U.dt_refund_amount) / SUM(U.dt_pay_ok_order_amount)
         ELSE 0 END AS dt_refund_amount_rate_30d,
    CASE WHEN SUM(U.dt_total_order_cnt) > 0
         THEN SUM(U.dt_cancel_order_cnt) / SUM(U.dt_total_order_cnt)
         ELSE 0 END AS dt_cancel_rate_30d,
    CASE WHEN SUM(U.dt_total_order_cnt) > 0
         THEN COALESCE(SUM(C.dt_compensation_order_cnt), 0) / SUM(U.dt_total_order_cnt)
         ELSE 0 END AS dt_compensation_rate_30d,
    CASE WHEN SUM(U.dt_pay_ok_order_amount) > 0
         THEN COALESCE(SUM(C.dt_total_compensation_amount), 0) / SUM(U.dt_pay_ok_order_amount)
         ELSE 0 END AS dt_compensation_amount_rate_30d,
    -- 身份聚集
    SUM(U.dt_distinct_pay_tool_cnt) AS dt_distinct_pay_tool_cnt_30d,
    SUM(U.dt_distinct_ip_cnt) AS dt_distinct_ip_cnt_30d,
    SUM(U.dt_distinct_contact_mob_cnt) AS dt_distinct_contact_mob_cnt_30d,
    SUM(U.dt_distinct_passenger_cnt) AS dt_distinct_passenger_cnt_30d,
    SUM(U.dt_distinct_passenger_card_cnt) AS dt_distinct_passenger_card_cnt_30d,
    -- 业务特有标记
    SUM(U.dt_scalper_cnt) AS dt_scalper_cnt_30d,
    SUM(U.dt_malice_cnt) AS dt_malice_cnt_30d,
    SUM(U.dt_huangniu_cnt) AS dt_huangniu_cnt_30d,
    SUM(U.dt_brush_cnt) AS dt_brush_cnt_30d,
    SUM(U.dt_zero_product_cnt) AS dt_zero_product_cnt_30d,
    SUM(U.dt_intercept_cnt) AS dt_intercept_cnt_30d,
    SUM(U.dt_abnormal_cancel_cnt) AS dt_abnormal_cancel_cnt_30d,
    SUM(U.dt_full_refund_cnt) AS dt_full_refund_cnt_30d,
    -- 金额
    SUM(U.dt_voucher_sum) AS dt_voucher_sum_30d,
    SUM(U.dt_coupon_sum) AS dt_coupon_sum_30d,
    SUM(U.dt_marketing_cashback_sum) AS dt_marketing_cashback_sum_30d,
    SUM(U.dt_subsidy_sum) AS dt_subsidy_sum_30d,
    MAX(U.dt_max_order_amount) AS dt_max_order_amount_30d,
    -- 时间
    SUM(U.dt_night_order_cnt) AS dt_night_order_cnt_30d,
    MIN(U.dt_min_refund_interval_sec) AS dt_min_refund_interval_sec_30d,
    -- 工单（需另关联 dws_device_workorder_daily，此处预留 NULL，python 二次加工）
    NULL AS dt_workorder_cnt_30d,
    NULL AS dt_workorder_reopen_cnt_30d,
    NULL AS dt_workorder_refund_type_cnt_30d,
    NULL AS dt_workorder_compensation_type_cnt_30d,
    -- G2 赔付（关联 comp 30d 窗口）
    COALESCE(SUM(C.dt_compensation_order_cnt), 0) AS dt_compensation_order_cnt_30d,
    COALESCE(SUM(C.dt_compensation_cnt), 0) AS dt_compensation_cnt_30d,
    COALESCE(SUM(C.dt_compensation_amount), 0) AS dt_compensation_amount_30d,
    COALESCE(SUM(C.dt_refund_amount), 0) AS dt_refund_amount_comp_30d,
    COALESCE(SUM(C.dt_consume_amount), 0) AS dt_consume_amount_30d,
    COALESCE(SUM(C.dt_total_compensation_amount), 0) AS dt_total_compensation_amount_30d,
    -- 单均赔付
    CASE WHEN SUM(U.dt_total_order_cnt) > 0
         THEN COALESCE(SUM(C.dt_total_compensation_amount), 0) / SUM(U.dt_total_order_cnt)
         ELSE 0 END AS dt_compensation_per_order_30d,
    COALESCE(SUM(C.dt_compensation_pay_success_cnt), 0) AS dt_compensation_pay_success_cnt_30d,
    COALESCE(SUM(C.dt_compensation_reject_cnt), 0) AS dt_compensation_reject_cnt_30d,
    CASE WHEN COALESCE(SUM(C.dt_compensation_cnt), 0) > 0
         THEN COALESCE(SUM(C.dt_compensation_reject_cnt), 0) / SUM(C.dt_compensation_cnt)
         ELSE 0 END AS dt_compensation_reject_rate_30d,
    COALESCE(SUM(C.dt_compensation_auto_pay_cnt), 0) AS dt_compensation_auto_pay_cnt_30d,
    CASE WHEN COALESCE(SUM(C.dt_compensation_cnt), 0) > 0
         THEN COALESCE(SUM(C.dt_compensation_auto_pay_cnt), 0) / SUM(C.dt_compensation_cnt)
         ELSE 0 END AS dt_compensation_auto_pay_rate_30d,
    MIN(C.dt_compensation_create_to_pay_interval_min_sec) AS dt_compensation_create_to_pay_min_sec_30d,
    MIN(C.dt_order_to_compensation_interval_min_sec) AS dt_order_to_compensation_min_sec_30d,
    COALESCE(SUM(C.dt_compensation_same_day_pay_cnt), 0) AS dt_compensation_same_day_pay_cnt_30d,
    -- 原因多样性（窗口内跨日去重需 python 再加工，SQL 取 MAX 近似）
    MAX(C.dt_distinct_problem_name_cnt) AS dt_distinct_problem_name_cnt_30d,
    MAX(C.dt_distinct_detail_reason_cnt) AS dt_distinct_detail_reason_cnt_30d,
    MAX(C.dt_distinct_responser_cnt) AS dt_distinct_responser_cnt_30d,
    MAX(C.dt_distinct_compensation_way_cnt) AS dt_distinct_compensation_way_cnt_30d,
    -- 金额分布
    AVG(C.dt_compensation_amount_avg) AS dt_compensation_amount_avg_30d,
    MAX(C.dt_compensation_amount_max) AS dt_compensation_amount_max_30d,
    COALESCE(SUM(C.dt_high_compensation_cnt), 0) AS dt_high_compensation_cnt_30d,
    -- 跨业务线（需另关联 dws_device_cross_biz_daily 30d 窗口，此处预留 NULL，python 二次加工）
    NULL AS dt_cross_biz_cnt_30d,
    NULL AS dt_cross_biz_order_cnt_30d,
    NULL AS dt_cross_biz_compensation_cnt_30d,
    NULL AS dt_cross_biz_compensation_amount_30d,
    NULL AS dt_cross_biz_compensation_biz_cnt_30d
FROM (
    -- 机票宽表
    SELECT
        dt, device_id, '机票' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, dt_refund_amount, dt_refund_order_cnt, dt_cancel_order_cnt,
        dt_distinct_user_id_cnt, dt_distinct_mobile_cnt, dt_distinct_email_cnt,
        dt_distinct_pay_tool_cnt, dt_distinct_ip_cnt, dt_distinct_contact_mob_cnt,
        dt_distinct_passenger_cnt, dt_distinct_passenger_card_cnt,
        dt_scalper_cnt, 0 AS dt_malice_cnt, 0 AS dt_huangniu_cnt, 0 AS dt_brush_cnt,
        0 AS dt_zero_product_cnt, dt_intercept_cnt, 0 AS dt_abnormal_cancel_cnt, 0 AS dt_full_refund_cnt,
        dt_voucher_sum, 0 AS dt_coupon_sum, 0 AS dt_marketing_cashback_sum, 0 AS dt_subsidy_sum,
        dt_max_order_amount, dt_night_order_cnt, dt_min_refund_pay_interval_sec
    FROM leiden.dws_device_flight_daily
    UNION ALL
    -- 酒店宽表
    SELECT
        dt, device_id, '酒店' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, 0 AS dt_refund_amount, 0 AS dt_refund_order_cnt, dt_cancel_order_cnt,
        0 AS dt_distinct_user_id_cnt, dt_distinct_contact_mob_cnt AS dt_distinct_mobile_cnt, 0 AS dt_distinct_email_cnt,
        0 AS dt_distinct_pay_tool_cnt, 0 AS dt_distinct_ip_cnt, dt_distinct_contact_mob_cnt,
        dt_distinct_guest_idcard_cnt AS dt_distinct_passenger_cnt, dt_distinct_guest_idcard_cnt AS dt_distinct_passenger_card_cnt,
        0 AS dt_scalper_cnt, dt_malice_cnt, 0 AS dt_huangniu_cnt, 0 AS dt_brush_cnt,
        0 AS dt_zero_product_cnt, 0 AS dt_intercept_cnt, dt_abnormal_cancel_cnt, 0 AS dt_full_refund_cnt,
        0 AS dt_voucher_sum, 0 AS dt_coupon_sum, 0 AS dt_marketing_cashback_sum, 0 AS dt_subsidy_sum,
        dt_max_order_amount, 0 AS dt_night_order_cnt, dt_refund_interval_avg_sec AS dt_min_refund_pay_interval_sec
    FROM leiden.dws_device_hotel_daily
    UNION ALL
    -- 门票宽表
    SELECT
        dt, device_id, '门票' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, dt_refund_money AS dt_refund_amount, dt_refund_order_cnt, 0 AS dt_cancel_order_cnt,
        0 AS dt_distinct_user_id_cnt, dt_distinct_mobile_cnt, 0 AS dt_distinct_email_cnt,
        0 AS dt_distinct_pay_tool_cnt, 0 AS dt_distinct_ip_cnt, dt_distinct_mobile_cnt AS dt_distinct_contact_mob_cnt,
        0 AS dt_distinct_passenger_cnt, 0 AS dt_distinct_passenger_card_cnt,
        0 AS dt_scalper_cnt, 0 AS dt_malice_cnt, dt_huangniu_cnt, dt_brush_cnt,
        dt_zero_product_cnt, 0 AS dt_intercept_cnt, 0 AS dt_abnormal_cancel_cnt, dt_full_refund_cnt,
        0 AS dt_voucher_sum, dt_coupon_sum, dt_marketing_cashback_sum, dt_subsidy_sum,
        dt_max_order_amount, 0 AS dt_night_order_cnt, dt_refund_pay_interval_avg_sec AS dt_min_refund_pay_interval_sec
    FROM leiden.dws_device_ticket_daily
) U
LEFT JOIN leiden.dws_device_compensation_daily C
  ON C.device_id = U.device_id
  AND C.dt = U.dt
  AND C.biz_line = U.biz_line
WHERE U.dt BETWEEN DATE_SUB(CAST('${DATE}' AS DATE), 29) AND CAST('${DATE}' AS DATE)
GROUP BY U.device_id;
