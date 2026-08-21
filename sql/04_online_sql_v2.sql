-- =====================================================================
-- Leiden 风险用户识别 - 线上 SQL（v2，含扩展指标）
-- 约束：
--   1. comp 查询保持原样，不改
--   2. 其余各业务线 DWD/DWS 全量重写
--   3. 新增支付-退款表 extdata 展开
--   4. 新增工单明细表
--   5. 新增酒店/门票 DWD
-- 含义见 docs/05_extended_metrics.md
-- =====================================================================

-- #####################################################################
-- Layer 2: DWD 离线明细表
-- #####################################################################

-- -------------------------------------------------------------------
-- 2.1 机票订单 DWD（新增字段）
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dwd_flight_order_di (
    dt                      STRING          COMMENT '日期分区',
    order_no                STRING          COMMENT '订单号 国内取main_order_no 国际取order_no',
    user_id                 STRING,
    username                STRING,
    status_code             INT,
    status_name             STRING,
    pay_ok                  INT,
    is_ticket_success       INT,
    is_apply_refund         INT,
    total_price             DECIMAL(18,2),
    total_ticket_price      DECIMAL(18,2),
    adult_price             DECIMAL(18,2)   COMMENT '成人票面总价',
    adult_tax               DECIMAL(18,2)   COMMENT '成人税费',
    child_price             DECIMAL(18,2),
    child_tax               DECIMAL(18,2),
    discount                DECIMAL(10,4)   COMMENT '折扣率',
    add_price_amount        DECIMAL(18,2)   COMMENT '加价金额',
    bottom_price            DECIMAL(18,2)   COMMENT '最低价底价',
    pricedepth_amount       DECIMAL(18,2)   COMMENT '价格深度金额',
    voucher_amount          DECIMAL(18,2)   COMMENT '代金券金额',
    express_price           DECIMAL(18,2)   COMMENT '快递费',
    service_fee_amount      DECIMAL(18,2)   COMMENT '服务费',
    exp_cut                 DECIMAL(18,2)   COMMENT '补贴金额',
    is_scalper              INT             COMMENT '是否黄牛',
    is_gp                   INT             COMMENT '是否高频',
    is_dxpd                 INT             COMMENT '是否大单',
    is_new                  INT             COMMENT '是否新客',
    is_fenxiao              INT             COMMENT '是否分销',
    intercept_result        STRING          COMMENT '拦截原因code',
    pre_day                 INT             COMMENT '提前购票天数',
    flight_size             INT             COMMENT '航段数',
    combine_order_type      STRING          COMMENT '合单类型',
    dep_city                STRING,
    arr_city                STRING,
    flight_num              STRING,
    cabin                   STRING,
    ip                      STRING,
    contact_mob             STRING,
    contact_email           STRING,
    create_time             TIMESTAMP       COMMENT '下单时间',
    pay_time                TIMESTAMP,
    ticket_time             TIMESTAMP       COMMENT '出票时间',
    refund_apply_time       TIMESTAMP,
    refund_complete_time    TIMESTAMP,
    passenger_name          ARRAY<STRING>,
    passenger_card_num      ARRAY<STRING>,
    passenger_mobile        ARRAY<STRING>,
    pay_tool_id             STRING          COMMENT '支付工具标识',
    pay_brand_name          STRING,
    refund_amount           DECIMAL(18,2)   COMMENT '退款金额 来自refund表'
) COMMENT '机票订单DWD明细 v2'
PARTITIONED BY (dt STRING)
STORED AS ORC;


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
    A.adult_price,
    A.adult_tax,
    A.child_price,
    A.child_tax,
    A.m_discount AS discount,
    A.add_price_amount,
    A.bottom_price,
    A.pricedepth_amount,
    A.voucher_amount,
    A.express_price,
    A.service_fee_amount,
    A.exp_cut,
    IF(A.is_scalper = '是', 1, 0) AS is_scalper,
    A.is_gp,
    A.is_dxpd,
    A.is_new,
    A.is_fenxiao,
    A.intercept_result,
    A.pre_day,
    A.flight_size,
    A.combine_order_type,
    A.dep_city,
    A.arr_city,
    A.flight_num,
    A.cabin,
    A.ip,
    A.contact_mob,
    A.contact_email,
    A.create_time,
    A.pay_time,
    A.ticket_time,
    A.refund_apply_time,
    A.refund_complete_time,
    P.guest_name AS passenger_name,
    P.guest_card_num AS passenger_card_num,
    P.guest_mobile AS passenger_mobile,
    C.pay_tool_id,
    C.pay_brand_name,
    R.refund_amount
FROM flight.dwd_ord_wide_order_di A
LEFT JOIN (
    SELECT
        IF(o_dom_inter = 1, o_main_order_no, o_order_no) AS order_no,
        array_remove(array_distinct(array_agg(p_passenger_name)), NULL) AS guest_name,
        array_remove(array_distinct(array_agg(p_card_num)), NULL) AS guest_card_num,
        array_remove(array_distinct(array_agg(p_mobile)), NULL) AS guest_mobile
    FROM flight.dwd_ord_wide_order_ticket_di
    WHERE dt = '${DATE}'
    GROUP BY 1
) P ON P.order_no = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
LEFT JOIN (
    SELECT
        orderid,
        MAX(COALESCE(cardnumf6l4join, regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1))) AS pay_tool_id,
        MAX(pay_brand_name) AS pay_brand_name
    FROM pp_pub.dwd_fin_sub_trade_payment_account_detail_di
    WHERE dt = '${DATE}'
      AND COALESCE(cardnumf6l4join, regexp_extract(pay_json, 'thirdUid":"(.*?)"', 1)) IS NOT NULL
    GROUP BY 1
) C ON C.orderid = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
LEFT JOIN (
    -- 修正13: refund先聚合到 orderid 粒度
    SELECT
        orderid,
        SUM(amt) AS refund_amount
    FROM pp_pub.dwd__qunar_selfpayord_di
    WHERE d = '${DATE}'
      AND order_type_change LIKE '%机票%'
      AND opertype = '退款'
    GROUP BY orderid
) R ON R.orderid = IF(A.dom_inter = 1, A.main_order_no, A.order_no)
WHERE A.dt = '${DATE}';


-- -------------------------------------------------------------------
-- 2.2 酒店 DWD
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dwd_hotel_order_di (
    dt                      STRING,
    order_no                STRING,
    user_id                 STRING,
    user_name               STRING,
    order_status           STRING          COMMENT '订单状态',
    pay_status              STRING          COMMENT '支付状态',
    pay_type                STRING          COMMENT '支付类型 CASH现付 PROXY预付',
    pay_method              STRING          COMMENT '支付渠道',
    payamount               DECIMAL(18,2)   COMMENT '支付金额组合',
    pay_time                TIMESTAMP,
    refund_time             TIMESTAMP,
    cancelled_time          TIMESTAMP,
    order_time              TIMESTAMP       COMMENT '预定时间',
    checkin_date            STRING,
    checkout_date           STRING,
    final_checkin_date      STRING,
    final_checkout_date     STRING,
    room_night              INT             COMMENT '间夜',
    final_room_night        INT,
    room_num                INT,
    room_type               STRING          COMMENT '物理房型',
    hotel_seq               STRING,
    hotel_name              STRING,
    hotel_grade             INT             COMMENT '酒店档次1-5',
    city_code               STRING,
    city_name               STRING,
    star_province_name      STRING,
    star_country_name       STRING,
    ip                      STRING          COMMENT '终端支付信息ip',
    contact_name            STRING,
    contact_phone           STRING,
    guest_idcard_info       STRING          COMMENT '住客身份证信息',
    is_guarantee            INT             COMMENT '是否担保',
    guarantee_type          STRING,
    guarantee_condition     STRING,
    guarantee_amount        DECIMAL(18,2),
    is_laterpay             INT             COMMENT '是否后付',
    is_hours_room           INT,
    is_pre_sale             INT,
    is_distribute           INT,
    is_malice               INT             COMMENT '是否恶意单',
    is_scan                 INT,
    is_singlemember        INT,
    is_valid                INT,
    is_ota_direct           INT,
    abnormal_condition_refund INT          COMMENT '规则外取消',
    buyout_type             STRING,
    defect_type             STRING,
    free_cancel_flag        INT,
    use_free_cancel         INT,
    cancel_distance         DECIMAL(18,2)   COMMENT '用户取消距离',
    user_hotel_distance     DECIMAL(18,2)   COMMENT '用户-酒店距离米',
    breakfast               INT             COMMENT '免费早餐份数',
    booking_window          INT,
    app_channel_id          STRING          COMMENT 'cid推广渠道号',
    app_name                STRING          COMMENT 'pid',
    app_version             STRING          COMMENT 'vid',
    device_id               STRING,
    orig_device_id          STRING,
    user_level              STRING,
    supplier_code           STRING,
    supplier_name           STRING,
    distributor_id          STRING,
    income_type             STRING          COMMENT '结算类型CPC/CPS/CPA',
    actual_success_paymode STRING          COMMENT '是否实际使用极速支付',
    pay_info                STRING,
    pay_trade_type          STRING,
    sub_auth_type           STRING
) COMMENT '酒店订单DWD明细'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dwd_hotel_order_di PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    order_no,
    user_id,
    user_name,
    order_status,
    pay_status,
    pay_type,
    pay_method,
    CAST(payamount AS DECIMAL(18,2)) AS payamount,
    CAST(pay_time AS TIMESTAMP) AS pay_time,
    CAST(refund_time AS TIMESTAMP) AS refund_time,
    CAST(cancelled_time AS TIMESTAMP) AS cancelled_time,
    CAST(order_time AS TIMESTAMP) AS order_time,
    checkin_date,
    checkout_date,
    final_checkin_date,
    final_checkout_date,
    CAST(room_night AS INT) AS room_night,
    CAST(final_room_night AS INT) AS final_room_night,
    CAST(room_num AS INT) AS room_num,
    physical_room_name AS room_type,
    hotel_seq,
    hotel_name,
    CAST(hotel_grade AS INT) AS hotel_grade,
    city_code,
    city_name,
    province_name AS star_province_name,
    country_name AS star_country_name,
    CAST(pay_info AS STRING) AS ip,           -- 酒店表 ip 在 pay_info 中，需业务方确认
    contact_name,
    contact_phone,
    guest_idcard_info,
    CAST(is_guarantee AS INT) AS is_guarantee,
    guarantee_type,
    guarantee_condition,
    CAST(JSON_EXTRACT(guarantee_amount, '$.amount') AS DECIMAL(18,2)) AS guarantee_amount,
    CAST(is_laterpay AS INT) AS is_laterpay,
    CAST(is_hours_room AS INT) AS is_hours_room,
    CAST(is_pre_sale AS INT) AS is_pre_sale,
    CAST(is_distribute AS INT) AS is_distribute,
    CAST(is_malice AS INT) AS is_malice,
    CAST(is_scan AS INT) AS is_scan,
    CAST(is_singlemember AS INT) AS is_singlemember,
    CAST(is_valid AS INT) AS is_valid,
    CAST(is_ota_direct AS INT) AS is_ota_direct,
    CAST(abnormal_condition_refund AS INT) AS abnormal_condition_refund,
    buyout_type,
    defect_type,
    CAST(free_cancel_flag AS INT) AS free_cancel_flag,
    CAST(use_free_cancel AS INT) AS use_free_cancel,
    CAST(cancel_distance AS DECIMAL(18,2)) AS cancel_distance,
    CAST(user_hotel_distance AS DECIMAL(18,2)) AS user_hotel_distance,
    CAST(breakfast AS INT) AS breakfast,
    CAST(booking_window AS INT) AS booking_window,
    app_channel_id,
    app_name,
    app_version,
    device_id,
    orig_device_id,
    user_level,
    supplier_code,
    supplier_name,
    distributor_id,
    income_type,
    actual_success_paymode,
    pay_info,
    pay_trade_type,
    sub_auth_type
FROM hotel.dwd_ord_order_detail_di
WHERE dt = '${DATE}'
  AND data_source = 'hms';


-- -------------------------------------------------------------------
-- 2.3 门票 DWD
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dwd_ticket_order_di (
    dt                          STRING,
    order_id                    STRING          COMMENT '订单id',
    order_display_id            STRING,
    parent_display_id           STRING,
    user_mobile                 STRING          COMMENT '手机号',
    order_create_time           TIMESTAMP,
    order_pay_time              TIMESTAMP,
    operate_time                TIMESTAMP,
    last_modified_time          TIMESTAMP,
    biz_type                    STRING          COMMENT '业务类型 门票/酒套/玩乐',
    order_status                INT             COMMENT '订单状态码',
    op_type                     STRING          COMMENT '操作类型 pay/refund',
    order_cannel_type           STRING,
    order_refund_status         INT             COMMENT '退款状态码',
    order_refund_times          TIMESTAMP,
    is_full_refund              INT,
    refund_money               DECIMAL(18,2),
    refund_reason              STRING,
    refund_type                STRING,
    order_quantity              INT,
    pay_quantity                INT,
    refund_quantity             INT,
    order_refund_quantity       INT,
    hcount                      INT             COMMENT '人次',
    money                       DECIMAL(18,2)   COMMENT '成交实际金额',
    pay_money                   DECIMAL(18,2),
    order_money                 DECIMAL(18,2),
    coupon_money                DECIMAL(18,2),
    coupon_money_final          DECIMAL(18,2),
    order_red_packet_money      DECIMAL(18,2),
    order_subsidy_money         DECIMAL(18,2),
    subsidy_money              DECIMAL(18,2),
    marketing_cashback_money   DECIMAL(18,2),
    marketing_lijian_money     DECIMAL(18,2),
    increase_income            DECIMAL(18,2),
    automatic_increase_income  DECIMAL(18,2),
    force_qunar_price_income   DECIMAL(18,2),
    order_force_qunar_price_income DECIMAL(18,2),
    income                     DECIMAL(18,2),
    purchase_cost              DECIMAL(18,2),
    order_settle_price         DECIMAL(18,2),
    filter_flag                INT             COMMENT '0正常 1测试 2黄牛 3子单 4组合 5一元 6扫码 7硬补 8包场 9刷票 10多级分销 11微信扫码',
    is_zero_product            INT,
    if_dabao                   INT,
    issue_speed                INT             COMMENT '出票速度秒',
    fp                          STRING          COMMENT '设备指纹',
    order_takeoff_date         STRING          COMMENT '入园时间',
    sight_id                   STRING,
    sight_name                 STRING,
    sight_city                 STRING,
    sight_region               STRING,
    sight_country              STRING,
    goods_id                   STRING,
    goods_name                 STRING,
    product_id                 STRING,
    product_name               STRING,
    supplier_id                STRING,
    supplier_name              STRING,
    supplier_shop_name         STRING,
    order_distributor_id       STRING,
    order_sale_platform        INT,
    order_sale_type            INT,
    order_self_operate         INT,
    order_straight_operate     INT,
    order_is_marketing_ticket  INT,
    order_is_qunar_operation   INT,
    source                     STRING,
    order_source               STRING,
    local_city                 STRING,
    local_region               STRING,
    user_mobile_city           STRING,
    user_mobile_region         STRING,
    trace_uid                  STRING,
    trace_gid                  STRING,
    trace_vid                  STRING,
    firstlv_tickettype_name    STRING,
    secondlv_category_grade_name STRING,
    customer_categories        STRING,
    journey_type              INT,
    day_trip_group_type       INT
) COMMENT '门票订单DWD明细'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dwd_ticket_order_di PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    CAST(order_id AS STRING) AS order_id,
    order_display_id,
    parent_display_id,
    order_contact_mobile AS user_mobile,
    CAST(order_create_time AS TIMESTAMP) AS order_create_time,
    CAST(order_pay_time AS TIMESTAMP) AS order_pay_time,
    CAST(operate_time AS TIMESTAMP) AS operate_time,
    CAST(last_modified_time AS TIMESTAMP) AS last_modified_time,
    biz_type,
    CAST(order_status AS INT) AS order_status,
    op_type,
    order_cannel_type,
    CAST(order_refund_status AS INT) AS order_refund_status,
    CAST(order_refund_times AS TIMESTAMP) AS order_refund_times,
    CAST(is_full_refund AS INT) AS is_full_refund,
    CAST(refund_money AS DECIMAL(18,2)) AS refund_money,
    refund_reason,
    refund_type,
    CAST(order_quantity AS INT) AS order_quantity,
    CAST(pay_quantity AS INT) AS pay_quantity,
    CAST(refund_quantity AS INT) AS refund_quantity,
    CAST(order_refund_quantity AS INT) AS order_refund_quantity,
    CAST(hcount AS INT) AS hcount,
    CAST(money AS DECIMAL(18,2)) AS money,
    CAST(pay_money AS DECIMAL(18,2)) AS pay_money,
    CAST(order_money AS DECIMAL(18,2)) AS order_money,
    CAST(coupon_money AS DECIMAL(18,2)) AS coupon_money,
    CAST(coupon_money_final AS DECIMAL(18,2)) AS coupon_money_final,
    CAST(order_red_packet_money AS DECIMAL(18,2)) AS order_red_packet_money,
    CAST(order_subsidy_money AS DECIMAL(18,2)) AS order_subsidy_money,
    CAST(subsidy_money AS DECIMAL(18,2)) AS subsidy_money,
    CAST(marketing_cashback_money AS DECIMAL(18,2)) AS marketing_cashback_money,
    CAST(marketing_lijian_money AS DECIMAL(18,2)) AS marketing_lijian_money,
    CAST(increase_income AS DECIMAL(18,2)) AS increase_income,
    CAST(automatic_increase_income AS DECIMAL(18,2)) AS automatic_increase_income,
    CAST(force_qunar_price_income AS DECIMAL(18,2)) AS force_qunar_price_income,
    CAST(order_force_qunar_price_income AS DECIMAL(18,2)) AS order_force_qunar_price_income,
    CAST(income AS DECIMAL(18,2)) AS income,
    CAST(purchase_cost AS DECIMAL(18,2)) AS purchase_cost,
    CAST(order_settle_price AS DECIMAL(18,2)) AS order_settle_price,
    CAST(filter_flag AS INT) AS filter_flag,
    CAST(is_zero_product AS INT) AS is_zero_product,
    CAST(if_dabao AS INT) AS if_dabao,
    CAST(issue_speed AS INT) AS issue_speed,
    fp,
    order_takeoff_date,
    sight_id,
    sight_name,
    sight_city,
    sight_region,
    sight_country,
    goods_id,
    goods_name,
    product_id,
    product_name,
    supplier_id,
    supplier_name,
    supplier_shop_name,
    order_distributor_id,
    CAST(order_sale_platform AS INT) AS order_sale_platform,
    CAST(order_sale_type AS INT) AS order_sale_type,
    CAST(order_self_operate AS INT) AS order_self_operate,
    CAST(order_straight_operate AS INT) AS order_straight_operate,
    CAST(order_is_marketing_ticket AS INT) AS order_is_marketing_ticket,
    CAST(order_is_qunar_operation AS INT) AS order_is_qunar_operation,
    source,
    order_source,
    local_city,
    local_region,
    user_mobile_city,
    user_mobile_region,
    trace_uid,
    trace_gid,
    trace_vid,
    firstlv_tickettype_name,
    secondlv_category_grade_name,
    customer_categories,
    CAST(journey_type AS INT) AS journey_type,
    CAST(day_trip_group_type AS INT) AS day_trip_group_type
FROM ticket.dwd_ord_order_detail_di   -- 需业务方确认源表名
WHERE dt = '${DATE}';


-- -------------------------------------------------------------------
-- 2.4 支付-退款 DWD（extdata 展开）
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dwd_pay_refund_di (
    dt                          STRING,
    orderid                     STRING,
    amt                         DECIMAL(16,4),
    brand_id                    STRING,
    brand_name                  STRING,
    opertype                    STRING          COMMENT '扣款/退款',
    order_type_change           STRING          COMMENT '映射新业务线',
    order_type_name             STRING,
    paymenttype                 STRING          COMMENT '支付方式大类',
    is_self                     STRING,
    merchantid                  STRING,
    merchantname                STRING,
    post_flag                   STRING,
    tag                         STRING,
    -- extdata 展开
    last_brand_id               STRING,
    cashier_type                STRING,
    new_post_flag               STRING,
    busi_order_no               STRING,
    promotion_investor          STRING,
    card_cnt                    BIGINT,
    default_paymentway_id       STRING,
    pay_user_id                 STRING          COMMENT 'extdata.user_id',
    platform                    STRING,
    pay_order_type              STRING,
    promotion_id               STRING,
    last_paycategory           STRING,
    card_orgnz                STRING
) COMMENT '支付-退款DWD明细 extdata展开'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dwd_pay_refund_di PARTITION(dt='${DATE}')
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
    tag,
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
WHERE d = '${DATE}';


-- -------------------------------------------------------------------
-- 2.5 工单明细 DWD
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dwd_workorder_detail_di (
    dt                          STRING,
    flow_log_id                 STRING          COMMENT '业务主键',
    flow_no                     STRING          COMMENT '工单号',
    order_no                    STRING          COMMENT '关联订单号',
    biz_line                    STRING,
    content_type                STRING          COMMENT '内容类型 CHAT/PHONE',
    channel_way                 STRING          COMMENT '渠道联络方式 AUTO/MANUAL',
    log_type                    STRING,
    short_content               STRING,
    content                     STRING,
    content_expansion           STRING,
    status_before               STRING,
    status_after                STRING,
    node_id_before              STRING,
    node_id_after               STRING,
    node_name_before             STRING,
    node_name_after             STRING,
    problem_ids_before          STRING,
    problem_ids_after           STRING,
    problem_names_before        STRING,
    problem_names_after         STRING,
    close_type                  STRING,
    close_solution_type_id      STRING,
    manager_id_before           STRING,
    manager_id_after            STRING,
    lock_id_before              STRING,
    lock_id_after               STRING,
    create_id                   STRING,
    create_name                 STRING,
    group_id                    STRING,
    workplace_id                STRING,
    ce_need_reply               INT,
    del                         INT,
    create_time                 TIMESTAMP,
    update_time                 TIMESTAMP
) COMMENT '工单明细DWD'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dwd_workorder_detail_di PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    flow_log_id,
    flow_no,
    order_no,
    biz_line,
    content_type,
    channel_way,
    log_type,
    short_content,
    content,
    content_expansion,
    status_before,
    status_after,
    node_id_before,
    node_id_after,
    node_name_before,
    node_name_after,
    problem_ids_before,
    problem_ids_after,
    problem_names_before,
    problem_names_after,
    close_type,
    close_solution_type_id,
    manager_id_before,
    manager_id_after,
    lock_id_before,
    lock_id_after,
    create_id,
    create_name,
    group_id,
    workplace_id,
    CAST(ce_need_reply AS INT) AS ce_need_reply,
    CAST(del AS INT) AS del,
    CAST(create_time AS TIMESTAMP) AS create_time,
    CAST(create_time AS TIMESTAMP) AS update_time    -- 工单表无独立update_time，用create_time
FROM default.ods_callcenterdb_workorder_detail        -- 需业务方确认源表名
WHERE dt = '${DATE}';


-- #####################################################################
-- Layer 3: DWS 用户-日宽表（含扩展指标）
-- #####################################################################

-- -------------------------------------------------------------------
-- 3.1 机票用户-日宽表
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dws_flight_user_daily (
    dt                          STRING,
    user_id                     STRING,
    dt_total_order_cnt          BIGINT,
    dt_pay_ok_order_cnt         BIGINT,
    dt_pay_ok_order_amount      DECIMAL(18,2),
    dt_ticket_success_order_cnt BIGINT,
    dt_cancel_order_cnt         BIGINT,
    dt_refund_order_cnt         BIGINT,
    dt_refund_amount            DECIMAL(18,2),
    dt_gq_order_cnt             BIGINT,
    -- 价格风险
    dt_avg_discount             DECIMAL(10,4),
    dt_min_discount             DECIMAL(10,4),
    dt_bottom_price_order_cnt   BIGINT          COMMENT '命中底价订单数',
    dt_add_price_sum            DECIMAL(18,2),
    dt_pricedepth_sum           DECIMAL(18,2),
    dt_voucher_sum              DECIMAL(18,2),
    dt_voucher_order_cnt        BIGINT,
    dt_express_price_sum        DECIMAL(18,2),
    dt_service_fee_sum          DECIMAL(18,2),
    dt_exp_cut_sum              DECIMAL(18,2),
    -- 行为异常
    dt_scalper_cnt              BIGINT,
    dt_gp_cnt                   BIGINT,
    dt_dxpd_cnt                 BIGINT,
    dt_intercept_cnt            BIGINT,
    dt_new_cnt                  BIGINT,
    dt_fenxiao_cnt              BIGINT,
    dt_pre_day_avg              DECIMAL(10,2),
    dt_flight_size_avg          DECIMAL(10,2),
    dt_combine_order_cnt        BIGINT,
    dt_distinct_dep_city_cnt    BIGINT,
    dt_distinct_arr_city_cnt    BIGINT,
    -- 时间分布
    dt_night_order_cnt          BIGINT          COMMENT '0-6点下单数',
    dt_weekend_order_cnt        BIGINT,
    -- 金额结构
    dt_adult_price_sum          DECIMAL(18,2),
    dt_adult_tax_sum            DECIMAL(18,2),
    -- 身份聚集
    dt_distinct_pay_tool_cnt    BIGINT,
    dt_distinct_ip_cnt          BIGINT,
    dt_distinct_contact_mob_cnt BIGINT,
    dt_distinct_passenger_cnt   BIGINT,
    dt_distinct_passenger_card_cnt BIGINT,
    dt_distinct_passenger_mobile_cnt BIGINT,
    dt_distinct_flight_num_cnt  BIGINT,
    dt_max_order_amount         DECIMAL(18,2),
    dt_min_pay_ticket_interval_sec BIGINT       COMMENT '最短支付到出票间隔秒',
    dt_min_refund_pay_interval_sec BIGINT       COMMENT '最短支付到退款间隔秒',
    dt_avg_refund_complete_interval_sec BIGINT
) COMMENT '机票用户-日宽表'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dws_flight_user_daily PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    user_id,
    COUNT(DISTINCT order_no) AS dt_total_order_cnt,
    COUNT(DISTINCT IF(pay_ok = 1, order_no, NULL)) AS dt_pay_ok_order_cnt,
    SUM(IF(pay_ok = 1, total_price, 0)) AS dt_pay_ok_order_amount,
    COUNT(DISTINCT IF(is_ticket_success = 1, order_no, NULL)) AS dt_ticket_success_order_cnt,
    COUNT(DISTINCT IF(status_name = '订单取消', order_no, NULL)) AS dt_cancel_order_cnt,
    COUNT(DISTINCT IF(status_name IN ('退款完成','退款完成自动','退款中','待退款','退款待确认'), order_no, NULL)) AS dt_refund_order_cnt,
    COALESCE(SUM(refund_amount), 0) AS dt_refund_amount,
    COUNT(DISTINCT IF(status_name IN ('改签完成','改签申请中'), order_no, NULL)) AS dt_gq_order_cnt,
    AVG(discount) AS dt_avg_discount,
    MIN(discount) AS dt_min_discount,
    COUNT(DISTINCT IF(total_price <= bottom_price, order_no, NULL)) AS dt_bottom_price_order_cnt,
    SUM(add_price_amount) AS dt_add_price_sum,
    SUM(pricedepth_amount) AS dt_pricedepth_sum,
    SUM(voucher_amount) AS dt_voucher_sum,
    COUNT(DISTINCT IF(voucher_amount > 0, order_no, NULL)) AS dt_voucher_order_cnt,
    SUM(express_price) AS dt_express_price_sum,
    SUM(service_fee_amount) AS dt_service_fee_sum,
    SUM(exp_cut) AS dt_exp_cut_sum,
    SUM(is_scalper) AS dt_scalper_cnt,
    SUM(is_gp) AS dt_gp_cnt,
    SUM(is_dxpd) AS dt_dxpd_cnt,
    COUNT(DISTINCT IF(intercept_result IS NOT NULL AND intercept_result != '', order_no, NULL)) AS dt_intercept_cnt,
    SUM(is_new) AS dt_new_cnt,
    SUM(is_fenxiao) AS dt_fenxiao_cnt,
    AVG(pre_day) AS dt_pre_day_avg,
    AVG(flight_size) AS dt_flight_size_avg,
    COUNT(DISTINCT IF(combine_order_type IS NOT NULL, order_no, NULL)) AS dt_combine_order_cnt,
    COUNT(DISTINCT dep_city) AS dt_distinct_dep_city_cnt,
    COUNT(DISTINCT arr_city) AS dt_distinct_arr_city_cnt,
    SUM(IF(HOUR(create_time) BETWEEN 0 AND 6, 1, 0)) AS dt_night_order_cnt,
    SUM(IF(DAYOFWEEK(create_time) IN (1, 7), 1, 0)) AS dt_weekend_order_cnt,
    SUM(adult_price) AS dt_adult_price_sum,
    SUM(adult_tax) AS dt_adult_tax_sum,
    COUNT(DISTINCT pay_tool_id) AS dt_distinct_pay_tool_cnt,
    COUNT(DISTINCT ip) AS dt_distinct_ip_cnt,
    COUNT(DISTINCT contact_mob) AS dt_distinct_contact_mob_cnt,
    SIZE(array_distinct(flatten(collect_set(passenger_name)))) AS dt_distinct_passenger_cnt,
    SIZE(array_distinct(flatten(collect_set(passenger_card_num)))) AS dt_distinct_passenger_card_cnt,
    SIZE(array_distinct(flatten(collect_set(passenger_mobile)))) AS dt_distinct_passenger_mobile_cnt,
    COUNT(DISTINCT flight_num) AS dt_distinct_flight_num_cnt,
    MAX(total_price) AS dt_max_order_amount,
    MIN(IF(pay_ok = 1 AND ticket_time IS NOT NULL, DATEDIFF(ticket_time, pay_time) * 86400, NULL)) AS dt_min_pay_ticket_interval_sec,
    MIN(IF(is_apply_refund = 1, DATEDIFF(refund_apply_time, pay_time) * 86400, NULL)) AS dt_min_refund_pay_interval_sec,
    AVG(IF(refund_complete_time IS NOT NULL AND refund_apply_time IS NOT NULL,
        DATEDIFF(refund_complete_time, refund_apply_time) * 86400, NULL)) AS dt_avg_refund_complete_interval_sec
FROM leiden.dwd_flight_order_di
WHERE dt = '${DATE}'
GROUP BY user_id;


-- -------------------------------------------------------------------
-- 3.2 酒店用户-日宽表
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dws_hotel_user_daily (
    dt                          STRING,
    user_id                     STRING,
    dt_total_order_cnt          BIGINT,
    dt_pay_ok_order_cnt         BIGINT,
    dt_pay_ok_order_amount      DECIMAL(18,2),
    dt_cancel_order_cnt         BIGINT,
    dt_abnormal_cancel_cnt      BIGINT,
    dt_refund_order_cnt         BIGINT,
    dt_guarantee_cnt            BIGINT,
    dt_guarantee_amount_sum     DECIMAL(18,2),
    dt_buyout_cnt               BIGINT,
    dt_laterpay_cnt             BIGINT,
    dt_hourroom_cnt             BIGINT,
    dt_malice_cnt               BIGINT,
    dt_defect_cnt               BIGINT,
    dt_distinct_hotel_cnt       BIGINT,
    dt_distinct_city_cnt        BIGINT,
    dt_cancel_distance_avg      DECIMAL(18,2),
    dt_user_hotel_distance_avg  DECIMAL(18,2),
    dt_pre_sale_cnt             BIGINT,
    dt_room_night_sum           BIGINT,
    dt_breakfast_sum            BIGINT,
    dt_distribute_cnt           BIGINT,
    dt_free_cancel_cnt          BIGINT,
    dt_singlemember_cnt         BIGINT,
    dt_invalid_cnt              BIGINT,
    dt_scan_cnt                 BIGINT,
    dt_actual_success_paymode_cnt BIGINT,
    dt_distinct_pay_tool_cnt    BIGINT,
    dt_distinct_ip_cnt          BIGINT,
    dt_distinct_contact_mob_cnt BIGINT,
    dt_max_order_amount         DECIMAL(18,2),
    dt_refund_interval_avg_sec  BIGINT
) COMMENT '酒店用户-日宽表'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dws_hotel_user_daily PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    user_id,
    COUNT(DISTINCT order_no) AS dt_total_order_cnt,
    COUNT(DISTINCT IF(pay_status = '已支付' OR pay_status = '支付成功', order_no, NULL)) AS dt_pay_ok_order_cnt,
    SUM(CAST(payamount AS DECIMAL(18,2))) AS dt_pay_ok_order_amount,
    COUNT(DISTINCT IF(order_status IN ('已取消','订单已取消'), order_no, NULL)) AS dt_cancel_order_cnt,
    SUM(abnormal_condition_refund) AS dt_abnormal_cancel_cnt,
    COUNT(DISTINCT IF(refund_time IS NOT NULL, order_no, NULL)) AS dt_refund_order_cnt,
    SUM(is_guarantee) AS dt_guarantee_cnt,
    SUM(guarantee_amount) AS dt_guarantee_amount_sum,
    COUNT(DISTINCT IF(buyout_type IS NOT NULL AND buyout_type != '', order_no, NULL)) AS dt_buyout_cnt,
    SUM(is_laterpay) AS dt_laterpay_cnt,
    SUM(is_hours_room) AS dt_hourroom_cnt,
    SUM(is_malice) AS dt_malice_cnt,
    COUNT(DISTINCT IF(defect_type IS NOT NULL AND defect_type != '', order_no, NULL)) AS dt_defect_cnt,
    COUNT(DISTINCT hotel_seq) AS dt_distinct_hotel_cnt,
    COUNT(DISTINCT city_code) AS dt_distinct_city_cnt,
    AVG(cancel_distance) AS dt_cancel_distance_avg,
    AVG(user_hotel_distance) AS dt_user_hotel_distance_avg,
    SUM(is_pre_sale) AS dt_pre_sale_cnt,
    SUM(COALESCE(final_room_night, room_night)) AS dt_room_night_sum,
    SUM(breakfast) AS dt_breakfast_sum,
    SUM(is_distribute) AS dt_distribute_cnt,
    SUM(COALESCE(use_free_cancel, free_cancel_flag)) AS dt_free_cancel_cnt,
    SUM(is_singlemember) AS dt_singlemember_cnt,
    SUM(IF(is_valid = 0, 1, 0)) AS dt_invalid_cnt,
    SUM(is_scan) AS dt_scan_cnt,
    COUNT(DISTINCT IF(actual_success_paymode IS NOT NULL AND actual_success_paymode != '', order_no, NULL)) AS dt_actual_success_paymode_cnt,
    -- 支付工具维度需关联支付表
    0 AS dt_distinct_pay_tool_cnt,
    0 AS dt_distinct_ip_cnt,
    COUNT(DISTINCT contact_phone) AS dt_distinct_contact_mob_cnt,
    MAX(payamount) AS dt_max_order_amount,
    AVG(IF(refund_time IS NOT NULL AND pay_time IS NOT NULL,
        DATEDIFF(refund_time, pay_time) * 86400, NULL)) AS dt_refund_interval_avg_sec
FROM leiden.dwd_hotel_order_di
WHERE dt = '${DATE}'
GROUP BY user_id;


-- -------------------------------------------------------------------
-- 3.3 门票用户-日宽表
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dws_ticket_user_daily (
    dt                          STRING,
    user_id                     STRING          COMMENT 'trace_uid 作 user_id',
    dt_total_order_cnt          BIGINT,
    dt_pay_ok_order_cnt         BIGINT,
    dt_pay_ok_order_amount      DECIMAL(18,2),
    dt_refund_order_cnt         BIGINT,
    dt_refund_money             DECIMAL(18,2),
    dt_full_refund_cnt          BIGINT,
    dt_refund_times_cnt         BIGINT,
    dt_auto_refund_fail_cnt     BIGINT,
    dt_supplier_reject_cnt      BIGINT,
    dt_qunar_reject_cnt         BIGINT,
    dt_huangniu_cnt             BIGINT,
    dt_test_cnt                 BIGINT,
    dt_brush_cnt                BIGINT,
    dt_zero_product_cnt         BIGINT,
    dt_one_yuan_cnt             BIGINT,
    dt_marketing_cashback_sum   DECIMAL(18,2),
    dt_marketing_lijian_sum     DECIMAL(18,2),
    dt_coupon_sum               DECIMAL(18,2),
    dt_red_packet_sum           DECIMAL(18,2),
    dt_subsidy_sum              DECIMAL(18,2),
    dt_increase_income_sum      DECIMAL(18,2),
    dt_force_price_sum          DECIMAL(18,2),
    dt_distinct_sight_cnt       BIGINT,
    dt_distinct_sight_city_cnt  BIGINT,
    dt_distinct_goods_cnt       BIGINT,
    dt_distinct_supplier_cnt    BIGINT,
    dt_hcount_sum               BIGINT,
    dt_issue_speed_avg          DECIMAL(18,2),
    dt_takeoff_pay_interval_avg_sec BIGINT,
    dt_refund_pay_interval_avg_sec BIGINT,
    dt_local_not_match_cnt      BIGINT,
    dt_dabao_cnt                BIGINT,
    dt_distinct_distributor_cnt BIGINT,
    dt_marketing_ticket_cnt     BIGINT,
    dt_self_operate_cnt         BIGINT,
    dt_b2b_cnt                  BIGINT,
    dt_distinct_pay_tool_cnt    BIGINT,
    dt_distinct_fp_cnt          BIGINT,
    dt_max_order_amount         DECIMAL(18,2)
) COMMENT '门票用户-日宽表'
PARTITIONED BY (dt STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dws_ticket_user_daily PARTITION(dt='${DATE}')
SELECT
    '${DATE}' AS dt,
    trace_uid AS user_id,
    COUNT(DISTINCT order_id) AS dt_total_order_cnt,
    COUNT(DISTINCT IF(op_type = 'pay' OR order_status IN (26, 33, 34), order_id, NULL)) AS dt_pay_ok_order_cnt,
    SUM(pay_money) AS dt_pay_ok_order_amount,
    COUNT(DISTINCT IF(op_type = 'refund' OR order_refund_status IN (27, 36, 22), order_id, NULL)) AS dt_refund_order_cnt,
    SUM(refund_money) AS dt_refund_money,
    SUM(is_full_refund) AS dt_full_refund_cnt,
    COUNT(DISTINCT IF(order_refund_times IS NOT NULL, order_id, NULL)) AS dt_refund_times_cnt,
    SUM(IF(order_refund_status = 21, 1, 0)) AS dt_auto_refund_fail_cnt,
    SUM(IF(order_refund_status = 24, 1, 0)) AS dt_supplier_reject_cnt,
    SUM(IF(order_refund_status = 26, 1, 0)) AS dt_qunar_reject_cnt,
    SUM(IF(filter_flag = 2, 1, 0)) AS dt_huangniu_cnt,
    SUM(IF(filter_flag = 1, 1, 0)) AS dt_test_cnt,
    SUM(IF(filter_flag = 9, 1, 0)) AS dt_brush_cnt,
    SUM(is_zero_product) AS dt_zero_product_cnt,
    SUM(IF(filter_flag = 5, 1, 0)) AS dt_one_yuan_cnt,
    SUM(marketing_cashback_money) AS dt_marketing_cashback_sum,
    SUM(marketing_lijian_money) AS dt_marketing_lijian_sum,
    SUM(coupon_money) AS dt_coupon_sum,
    SUM(order_red_packet_money) AS dt_red_packet_sum,
    SUM(COALESCE(order_subsidy_money, subsidy_money)) AS dt_subsidy_sum,
    SUM(increase_income) AS dt_increase_income_sum,
    SUM(COALESCE(force_qunar_price_income, order_force_qunar_price_income)) AS dt_force_price_sum,
    COUNT(DISTINCT sight_id) AS dt_distinct_sight_cnt,
    COUNT(DISTINCT sight_city) AS dt_distinct_sight_city_cnt,
    COUNT(DISTINCT goods_id) AS dt_distinct_goods_cnt,
    COUNT(DISTINCT supplier_id) AS dt_distinct_supplier_cnt,
    SUM(hcount) AS dt_hcount_sum,
    AVG(issue_speed) AS dt_issue_speed_avg,
    AVG(IF(order_takeoff_date IS NOT NULL AND order_pay_time IS NOT NULL,
        DATEDIFF(CAST(order_takeoff_date AS TIMESTAMP), order_pay_time) * 86400, NULL)) AS dt_takeoff_pay_interval_avg_sec,
    AVG(IF(order_refund_times IS NOT NULL AND order_pay_time IS NOT NULL,
        DATEDIFF(order_refund_times, order_pay_time) * 86400, NULL)) AS dt_refund_pay_interval_avg_sec,
    SUM(IF(local_city IS NOT NULL AND sight_city IS NOT NULL AND local_city != sight_city, 1, 0)) AS dt_local_not_match_cnt,
    SUM(if_dabao) AS dt_dabao_cnt,
    COUNT(DISTINCT order_distributor_id) AS dt_distinct_distributor_cnt,
    SUM(order_is_marketing_ticket) AS dt_marketing_ticket_cnt,
    SUM(order_self_operate) AS dt_self_operate_cnt,
    SUM(IF(order_sale_type = 1, 1, 0)) AS dt_b2b_cnt,
    0 AS dt_distinct_pay_tool_cnt,
    COUNT(DISTINCT fp) AS dt_distinct_fp_cnt,
    MAX(money) AS dt_max_order_amount
FROM leiden.dwd_ticket_order_di
WHERE dt = '${DATE}'
  AND trace_uid IS NOT NULL AND trace_uid != ''
GROUP BY trace_uid;


-- -------------------------------------------------------------------
-- 3.4 支付-退款用户-日宽表（extdata 展开）
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dws_pay_refund_user_daily (
    dt                          STRING,
    user_id                     STRING          COMMENT 'extdata.user_id',
    biz_line                    STRING          COMMENT 'order_type_change',
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
) COMMENT '支付-退款用户-日宽表'
PARTITIONED BY (dt STRING, biz_line STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dws_pay_refund_user_daily PARTITION(dt='${DATE}', biz_line)
SELECT
    '${DATE}' AS dt,
    pay_user_id AS user_id,
    order_type_change AS biz_line,
    COUNT(DISTINCT IF(opertype = '扣款', orderid, NULL)) AS dt_pay_cnt,
    SUM(IF(opertype = '扣款', amt, 0)) AS dt_pay_amt_sum,
    COUNT(DISTINCT IF(opertype = '退款', orderid, NULL)) AS dt_refund_cnt,
    SUM(IF(opertype = '退款', amt, 0)) AS dt_refund_amt_sum,
    COUNT(DISTINCT brand_id) AS dt_distinct_brand_id_cnt,
    COUNT(DISTINCT brand_name) AS dt_distinct_brand_name_cnt,
    COUNT(DISTINCT merchantid) AS dt_distinct_merchantid_cnt,
    COUNT(DISTINCT merchantname) AS dt_distinct_merchantname_cnt,
    COUNT(DISTINCT paymenttype) AS dt_distinct_paymenttype_cnt,
    COUNT(DISTINCT card_cnt) AS dt_distinct_card_cnt,
    AVG(card_cnt) AS dt_card_cnt_avg,
    MAX(card_cnt) AS dt_card_cnt_max,
    COUNT(DISTINCT card_orgnz) AS dt_distinct_card_orgnz_cnt,
    COUNT(DISTINCT last_brand_id) AS dt_distinct_last_brand_id_cnt,
    COUNT(DISTINCT last_paycategory) AS dt_distinct_last_paycategory_cnt,
    COUNT(DISTINCT default_paymentway_id) AS dt_distinct_default_paymentway_cnt,
    COUNT(DISTINCT promotion_id) AS dt_distinct_promotion_id_cnt,
    COUNT(DISTINCT promotion_investor) AS dt_distinct_promotion_investor_cnt,
    COUNT(DISTINCT cashier_type) AS dt_distinct_cashier_type_cnt,
    COUNT(DISTINCT post_flag) AS dt_distinct_post_flag_cnt,
    COUNT(DISTINCT new_post_flag) AS dt_distinct_new_post_flag_cnt,
    COUNT(DISTINCT platform) AS dt_distinct_platform_cnt,
    SUM(IF(opertype = '退款' AND is_self = '1', 1, 0)) AS dt_self_refund_cnt,
    SUM(IF(opertype = '退款', 1, 0)) AS dt_same_day_refund_cnt   -- 简化：当日退款笔数
FROM leiden.dwd_pay_refund_di
WHERE dt = '${DATE}'
  AND pay_user_id IS NOT NULL AND pay_user_id != ''
GROUP BY pay_user_id, order_type_change;


-- -------------------------------------------------------------------
-- 3.5 工单明细用户-日宽表
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leiden.dws_workorder_user_daily (
    dt                          STRING,
    user_id                     STRING          COMMENT '通过 order_no 反查订单表取user_id',
    biz_line                    STRING,
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
) COMMENT '工单明细用户-日宽表'
PARTITIONED BY (dt STRING, biz_line STRING)
STORED AS ORC;


INSERT OVERWRITE TABLE leiden.dws_workorder_user_daily PARTITION(dt='${DATE}', biz_line)
SELECT
    '${DATE}' AS dt,
    U.user_id,
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
    SIZE(array_distinct(flatten(collect_set(split(W.problem_names_after, ','))))) AS dt_problem_type_cnt,
    COUNT(DISTINCT W.close_solution_type_id) AS dt_close_solution_type_cnt,
    COUNT(DISTINCT W.close_type) AS dt_close_type_cnt,
    SUM(W.del) AS dt_del_cnt,
    SUM(W.ce_need_reply) AS dt_ce_need_reply_cnt,
    COUNT(DISTINCT W.create_id) AS dt_distinct_create_id_cnt,
    COUNT(DISTINCT W.workplace_id) AS dt_distinct_workplace_cnt,
    COUNT(DISTINCT W.group_id) AS dt_distinct_group_cnt,
    COUNT(DISTINCT W.log_type) AS dt_log_type_cnt,
    SUM(IF(W.order_no IS NULL OR W.order_no = '', 1, 0)) AS dt_no_order_workorder_cnt,
    SUM(IF(W.problem_names_after LIKE '%退款%', 1, 0)) AS dt_refund_type_workorder_cnt,
    SUM(IF(W.problem_names_after LIKE '%赔付%' OR W.problem_names_after LIKE '%补偿%', 1, 0)) AS dt_compensation_type_workorder_cnt
FROM leiden.dwd_workorder_detail_di W
LEFT JOIN (
    -- 通过 order_no 反查 user_id（机票+酒店+门票 union）
    SELECT order_no, user_id, '机票' AS biz_line FROM leiden.dwd_flight_order_di WHERE dt = '${DATE}'
    UNION ALL
    SELECT order_no, user_id, '酒店' AS biz_line FROM leiden.dwd_hotel_order_di WHERE dt = '${DATE}'
    UNION ALL
    SELECT order_id AS order_no, trace_uid AS user_id, '门票' AS biz_line FROM leiden.dwd_ticket_order_di WHERE dt = '${DATE}'
) U ON U.order_no = W.order_no
WHERE W.dt = '${DATE}'
  AND U.user_id IS NOT NULL
GROUP BY U.user_id, W.biz_line;


-- #####################################################################
-- Layer 3.6: 跨业务线汇总
-- #####################################################################
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
    dt_cross_distinct_mobile_cnt    BIGINT,
    dt_cross_distinct_passenger_cnt BIGINT,
    dt_cross_workorder_cnt          BIGINT,
    dt_cross_scalper_cnt            BIGINT,
    dt_cross_malice_cnt             BIGINT
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
    SUM(dt_distinct_contact_mob_cnt) AS dt_cross_distinct_mobile_cnt,
    SUM(dt_distinct_passenger_cnt) AS dt_cross_distinct_passenger_cnt,
    SUM(dt_workorder_cnt) AS dt_cross_workorder_cnt,
    SUM(dt_scalper_cnt) AS dt_cross_scalper_cnt,
    SUM(dt_malice_cnt) AS dt_cross_malice_cnt
FROM (
    SELECT user_id, '机票' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, dt_refund_amount,
        dt_distinct_pay_tool_cnt, dt_distinct_ip_cnt, dt_distinct_contact_mob_cnt,
        dt_distinct_passenger_cnt, 0 AS dt_compensation_amount,
        0 AS dt_workorder_cnt, dt_scalper_cnt, 0 AS dt_malice_cnt
    FROM leiden.dws_flight_user_daily WHERE dt = '${DATE}'
    UNION ALL
    SELECT user_id, '酒店' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, 0 AS dt_refund_amount,
        dt_distinct_pay_tool_cnt, dt_distinct_ip_cnt, dt_distinct_contact_mob_cnt,
        0 AS dt_distinct_passenger_cnt, 0 AS dt_compensation_amount,
        0 AS dt_workorder_cnt, 0 AS dt_scalper_cnt, dt_malice_cnt
    FROM leiden.dws_hotel_user_daily WHERE dt = '${DATE}'
    UNION ALL
    SELECT user_id, '门票' AS biz_line,
        dt_total_order_cnt, dt_pay_ok_order_amount, dt_refund_money,
        dt_distinct_pay_tool_cnt, 0 AS dt_distinct_ip_cnt, 0 AS dt_distinct_contact_mob_cnt,
        0 AS dt_distinct_passenger_cnt, 0 AS dt_compensation_amount,
        0 AS dt_workorder_cnt, 0 AS dt_scalper_cnt, 0 AS dt_malice_cnt
    FROM leiden.dws_ticket_user_daily WHERE dt = '${DATE}'
) U
GROUP BY user_id;


-- #####################################################################
-- Layer 4: 用户-特征宽表（按业务线 + 跨业务线）
-- 用 7/30/90 滚动窗口，由 python 完成最终特征拼装
-- 线上产出 DWS 即可
-- #####################################################################
-- 见 docs/05_extended_metrics.md 与 python/01_feature_engineering.py v2
