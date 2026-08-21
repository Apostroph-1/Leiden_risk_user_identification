"""
Leiden 风险用户识别 - 标签生成
按 docs/02_field_design.md 第五节口径，回溯标注
写入 mysql leiden.label_user_risk
"""
import os
import argparse
from datetime import datetime, timedelta
import pandas as pd
import numpy as np
from sqlalchemy import create_engine

MYSQL_URL = os.getenv("MYSQL_URL", "mysql+pymysql://root:root@localhost:3306/leiden?charset=utf8mb4")

# 标签阈值（初版，见 docs/02_field_design.md）
THRESHOLDS = {
    "is_refund_abuser":        {"refund_rate_30d": 0.5, "refund_amount_rate_30d": 0.3},
    "is_compensation_abuser":  {"compensation_rate_30d": 0.3, "compensation_amount_rate_30d": 0.2},
    "is_cancel_abuser":        {"cancel_rate_30d": 0.5, "order_cnt_30d_min": 5},
    "is_identity_fraud":       {"pay_tool_or_ip_or_mob_min": 5},
    "is_cross_biz_abuser":     {"cross_biz_cnt_30d_min": 3, "compensation_rate_30d_min": 0.3},
}


def build_labels(snapshot_dt: datetime, write_mysql: bool = True):
    engine = create_engine(MYSQL_URL)
    # 取当日特征
    f = pd.read_sql(
        f"SELECT * FROM feature_user_risk_profile WHERE snapshot_dt = '{snapshot_dt.date()}'",
        engine
    )
    if f.empty:
        print("特征表为空，跳过")
        return

    labels = pd.DataFrame()
    labels["snapshot_dt"] = f["snapshot_dt"]
    labels["user_id"] = f["user_id"]

    # 1. 退款滥用
    cond = (f["refund_rate_30d"] >= THRESHOLDS["is_refund_abuser"]["refund_rate_30d"]) & \
           (f["refund_amount_rate_30d"] >= THRESHOLDS["is_refund_abuser"]["refund_amount_rate_30d"])
    labels["is_refund_abuser"] = cond.astype(int)

    # 2. 赔付滥用
    cond = (f["compensation_rate_30d"] >= THRESHOLDS["is_compensation_abuser"]["compensation_rate_30d"]) & \
           (f["compensation_amount_rate_30d"] >= THRESHOLDS["is_compensation_abuser"]["compensation_amount_rate_30d"])
    labels["is_compensation_abuser"] = cond.astype(int)

    # 3. 恶意取消
    cond = (f["cancel_rate_30d"] >= THRESHOLDS["is_cancel_abuser"]["cancel_rate_30d"]) & \
           (f["order_cnt_30d"] >= THRESHOLDS["is_cancel_abuser"]["order_cnt_30d_min"])
    labels["is_cancel_abuser"] = cond.astype(int)

    # 4. 身份聚集
    cond = (f["distinct_pay_tool_cnt_30d"] >= THRESHOLDS["is_identity_fraud"]["pay_tool_or_ip_or_mob_min"]) | \
           (f["distinct_ip_cnt_30d"] >= THRESHOLDS["is_identity_fraud"]["pay_tool_or_ip_or_mob_min"]) | \
           (f["distinct_contact_mob_cnt_30d"] >= THRESHOLDS["is_identity_fraud"]["pay_tool_or_ip_or_mob_min"])
    labels["is_identity_fraud"] = cond.astype(int)

    # 5. 跨业务线薅羊毛
    cond = (f["cross_biz_cnt_30d"] >= THRESHOLDS["is_cross_biz_abuser"]["cross_biz_cnt_30d_min"]) & \
           (f["compensation_rate_30d"] >= THRESHOLDS["is_cross_biz_abuser"]["compensation_rate_30d_min"])
    labels["is_cross_biz_abuser"] = cond.astype(int)

    # 综合
    sub = ["is_refund_abuser", "is_compensation_abuser", "is_cancel_abuser",
           "is_identity_fraud", "is_cross_biz_abuser"]
    labels["is_risk_user"] = (labels[sub].sum(axis=1) > 0).astype(int)

    print(f"[标签] snapshot={snapshot_dt.date()} 总用户={len(labels)} 风险={labels['is_risk_user'].sum()}")

    if write_mysql:
        with engine.connect() as conn:
            conn.execute(f"DELETE FROM label_user_risk WHERE snapshot_dt = '{snapshot_dt.date()}'")
            conn.commit()
        labels.to_sql("label_user_risk", engine, if_exists="append", index=False, chunksize=2000)
        print(f"[写入 mysql] label_user_risk {snapshot_dt.date()}")

    return labels


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", required=False, default=None)
    args = parser.parse_args()
    snap = datetime.strptime(args.date, "%Y-%m-%d") if args.date else datetime.now() - timedelta(days=1)
    build_labels(snap)
