-- =====================================================================
-- 离线表导出 mysql 语句模板
-- 视数据量大小选择：(A) 直连 CH 用 federated 查询；(B) 导 CSV 再 LOAD DATA
-- 推荐 (B)：python 脚本 pandas 读 CH → 写 mysql，见 python/04_export_to_mysql.py
-- 这里给出 mysql 侧 LOAD DATA 模板
-- =====================================================================

USE leiden;

-- 导入 dws_user_biz_daily
-- 从 ClickHouse 导出为 TSV
LOAD DATA LOCAL INFILE '/path/to/dws_user_biz_daily.tsv'
INTO TABLE dws_user_biz_daily
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t' ENCLOSED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(dt, biz_line, user_id,
 dt_total_order_cnt, dt_pay_ok_order_cnt, dt_pay_ok_order_amount,
 dt_ticket_success_order_cnt, dt_cancel_order_cnt,
 dt_refund_order_cnt, dt_refund_amount, dt_gq_order_cnt,
 dt_compensation_cnt, dt_compensation_amount,
 dt_distinct_pay_tool_cnt, dt_distinct_ip_cnt,
 dt_distinct_contact_mob_cnt, dt_distinct_passenger_cnt,
 dt_max_order_amount);


-- 导入 dws_user_cross_biz_daily
LOAD DATA LOCAL INFILE '/path/to/dws_user_cross_biz_daily.tsv'
INTO TABLE dws_user_cross_biz_daily
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(dt, user_id,
 dt_cross_order_cnt, dt_cross_biz_cnt,
 dt_cross_pay_ok_amount, dt_cross_refund_amount,
 dt_cross_compensation_amount,
 dt_cross_distinct_pay_tool_cnt,
 dt_cross_distinct_ip_cnt,
 dt_cross_distinct_mobile_cnt);


-- 增量更新模板（每日 T+1）
-- 建议直接用 python to_sql if_exists='append' 或 REPLACE INTO
REPLACE INTO dws_user_biz_daily
(dt, biz_line, user_id, dt_total_order_cnt, dt_pay_ok_order_cnt, dt_pay_ok_order_amount,
 dt_ticket_success_order_cnt, dt_cancel_order_cnt, dt_refund_order_cnt, dt_refund_amount,
 dt_gq_order_cnt, dt_compensation_cnt, dt_compensation_amount,
 dt_distinct_pay_tool_cnt, dt_distinct_ip_cnt, dt_distinct_contact_mob_cnt,
 dt_distinct_passenger_cnt, dt_max_order_amount)
SELECT * FROM tmp_dws_user_biz_daily WHERE dt = CURDATE() - INTERVAL 1 DAY;
