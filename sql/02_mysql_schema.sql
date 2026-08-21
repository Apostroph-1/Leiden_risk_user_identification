-- =====================================================================
-- Leiden 风险模型 - MySQL 库表结构
-- 用途：本地 mysql 存储 DWS/特征/标签/模型输出，供 python 与 Tableau 使用
-- =====================================================================

CREATE DATABASE IF NOT EXISTS leiden DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE leiden;

-- -------------------------------------------------------------------
-- 用户-业务线-日宽表（从离线导出）
-- -------------------------------------------------------------------
DROP TABLE IF EXISTS dws_user_biz_daily;
CREATE TABLE dws_user_biz_daily (
    dt                          DATE            NOT NULL,
    biz_line                    VARCHAR(32)     NOT NULL,
    user_id                     VARCHAR(64)     NOT NULL,
    dt_total_order_cnt          BIGINT,
    dt_pay_ok_order_cnt         BIGINT,
    dt_pay_ok_order_amount      DECIMAL(18,2),
    dt_ticket_success_order_cnt BIGINT,
    dt_cancel_order_cnt         BIGINT,
    dt_refund_order_cnt         BIGINT,
    dt_refund_amount            DECIMAL(18,2),
    dt_gq_order_cnt             BIGINT,
    dt_compensation_cnt         BIGINT,
    dt_compensation_amount      DECIMAL(18,2),
    dt_distinct_pay_tool_cnt    BIGINT,
    dt_distinct_ip_cnt          BIGINT,
    dt_distinct_contact_mob_cnt BIGINT,
    dt_distinct_passenger_cnt   BIGINT,
    dt_max_order_amount         DECIMAL(18,2),
    PRIMARY KEY (dt, biz_line, user_id),
    KEY idx_user_dt (user_id, dt),
    KEY idx_dt_biz (dt, biz_line)
) ENGINE=InnoDB COMMENT='用户-业务线-日宽表';


-- -------------------------------------------------------------------
-- 跨业务线用户-日汇总
-- -------------------------------------------------------------------
DROP TABLE IF EXISTS dws_user_cross_biz_daily;
CREATE TABLE dws_user_cross_biz_daily (
    dt                              DATE            NOT NULL,
    user_id                         VARCHAR(64)     NOT NULL,
    dt_cross_order_cnt              BIGINT,
    dt_cross_biz_cnt                BIGINT,
    dt_cross_pay_ok_amount          DECIMAL(18,2),
    dt_cross_refund_amount          DECIMAL(18,2),
    dt_cross_compensation_amount    DECIMAL(18,2),
    dt_cross_distinct_pay_tool_cnt  BIGINT,
    dt_cross_distinct_ip_cnt        BIGINT,
    dt_cross_distinct_mobile_cnt    BIGINT,
    PRIMARY KEY (dt, user_id),
    KEY idx_user (user_id, dt)
) ENGINE=InnoDB COMMENT='跨业务线用户-日汇总';


-- -------------------------------------------------------------------
-- 特征表（python 产出）
-- -------------------------------------------------------------------
DROP TABLE IF EXISTS feature_user_risk_profile;
CREATE TABLE feature_user_risk_profile (
    snapshot_dt                 DATE            NOT NULL,
    user_id                     VARCHAR(64)     NOT NULL,
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
    refund_rate_7d              DECIMAL(6,4),
    refund_rate_30d             DECIMAL(6,4),
    refund_rate_90d             DECIMAL(6,4),
    refund_amount_rate_7d       DECIMAL(6,4),
    refund_amount_rate_30d      DECIMAL(6,4),
    refund_amount_rate_90d      DECIMAL(6,4),
    cancel_rate_7d              DECIMAL(6,4),
    cancel_rate_30d             DECIMAL(6,4),
    cancel_rate_90d             DECIMAL(6,4),
    compensation_rate_7d        DECIMAL(6,4),
    compensation_rate_30d       DECIMAL(6,4),
    compensation_rate_90d       DECIMAL(6,4),
    compensation_amount_rate_7d DECIMAL(6,4),
    compensation_amount_rate_30d DECIMAL(6,4),
    compensation_amount_rate_90d DECIMAL(6,4),
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
    min_interval_between_order_min_7d BIGINT   COMMENT '秒',
    max_order_amount_30d       DECIMAL(18,2),
    night_order_cnt_30d        BIGINT          COMMENT '0-6点下单数',
    same_flight_diff_passenger_cnt_30d BIGINT,
    same_passenger_diff_user_cnt_30d   BIGINT,
    cross_biz_burst_cnt_7d     BIGINT,
    -- 客诉
    compensation_reject_cnt_30d BIGINT,
    compensation_auto_pay_rate_30d DECIMAL(6,4),
    distinct_problem_type_cnt_30d BIGINT,
    PRIMARY KEY (snapshot_dt, user_id),
    KEY idx_user (user_id),
    KEY idx_snapshot (snapshot_dt)
) ENGINE=InnoDB COMMENT='用户风险特征表';


-- -------------------------------------------------------------------
-- 标签表（python 回溯标注）
-- -------------------------------------------------------------------
DROP TABLE IF EXISTS label_user_risk;
CREATE TABLE label_user_risk (
    snapshot_dt             DATE            NOT NULL,
    user_id                 VARCHAR(64)     NOT NULL,
    is_refund_abuser        TINYINT,
    is_compensation_abuser  TINYINT,
    is_cancel_abuser        TINYINT,
    is_identity_fraud       TINYINT,
    is_cross_biz_abuser     TINYINT,
    is_risk_user            TINYINT,
    PRIMARY KEY (snapshot_dt, user_id),
    KEY idx_snapshot_risk (snapshot_dt, is_risk_user)
) ENGINE=InnoDB COMMENT='风险用户标签表';


-- -------------------------------------------------------------------
-- 模型输出表
-- -------------------------------------------------------------------
DROP TABLE IF EXISTS model_user_risk_score;
CREATE TABLE model_user_risk_score (
    snapshot_dt         DATE            NOT NULL,
    user_id             VARCHAR(64)     NOT NULL,
    risk_score          DECIMAL(5,2)    COMMENT '0-100',
    risk_level          VARCHAR(16)     COMMENT '低/中/高',
    is_risk_user        TINYINT         COMMENT '模型预测 是否风险用户',
    hit_rules           VARCHAR(512)    COMMENT '命中规则 列表逗号分隔',
    top_features        TEXT            COMMENT 'Top贡献特征 JSON',
    model_version       VARCHAR(32),
    update_time         DATETIME,
    PRIMARY KEY (snapshot_dt, user_id),
    KEY idx_score (snapshot_dt, risk_score DESC),
    KEY idx_risk (snapshot_dt, is_risk_user)
) ENGINE=InnoDB COMMENT='模型输出风险评分表';
