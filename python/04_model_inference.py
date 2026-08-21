"""
Leiden 风险用户识别 - 模型推理 + 写 mysql
读取最新模型，对当日特征打分，写 model_user_risk_score
"""
import os
import json
import argparse
from datetime import datetime, timedelta
import joblib
import pandas as pd
import numpy as np
from sqlalchemy import create_engine

MYSQL_URL = os.getenv("MYSQL_URL", "mysql+pymysql://root:root@localhost:3306/leiden?charset=utf8mb4")
MODEL_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "model")

# 命中规则阈值（与标签一致，用于可解释输出）
RULE_THRESHOLDS = {
    "is_refund_abuser":        lambda f: (f["refund_rate_30d"] >= 0.5) & (f["refund_amount_rate_30d"] >= 0.3),
    "is_compensation_abuser":  lambda f: (f["compensation_rate_30d"] >= 0.3) & (f["compensation_amount_rate_30d"] >= 0.2),
    "is_cancel_abuser":        lambda f: (f["cancel_rate_30d"] >= 0.5) & (f["order_cnt_30d"] >= 5),
    "is_identity_fraud":       lambda f: (f["distinct_pay_tool_cnt_30d"] >= 5) | (f["distinct_ip_cnt_30d"] >= 5) | (f["distinct_contact_mob_cnt_30d"] >= 5),
    "is_cross_biz_abuser":     lambda f: (f["cross_biz_cnt_30d"] >= 3) & (f["compensation_rate_30d"] >= 0.3),
}


def load_latest_model():
    files = sorted([f for f in os.listdir(MODEL_DIR) if f.startswith("lgb_") and f.endswith(".pkl")])
    if not files:
        return None, None
    path = os.path.join(MODEL_DIR, files[-1])
    obj = joblib.load(path)
    return obj["model"], obj["version"]


def infer(snapshot_dt: datetime):
    engine = create_engine(MYSQL_URL)
    f = pd.read_sql(
        f"SELECT * FROM feature_user_risk_profile WHERE snapshot_dt = '{snapshot_dt.date()}'",
        engine
    )
    if f.empty:
        print("特征表为空")
        return

    model, version = load_latest_model()
    feats = obj = joblib.load(os.path.join(MODEL_DIR, sorted([f for f in os.listdir(MODEL_DIR) if f.startswith("lgb_")])[-1]))["features"] if model else None

    out = f[["snapshot_dt", "user_id"]].copy()

    if model is not None:
        X = f[feats].fillna(0).values
        proba = model.predict_proba(X)[:, 1]
        out["risk_score"] = np.round(proba * 100, 2)
        out["risk_level"] = pd.cut(out["risk_score"], [0, 30, 70, 100], labels=["低", "中", "高"], include_lowest=True)
        out["is_risk_user"] = (out["risk_score"] >= 50).astype(int)
    else:
        # 没有模型时退化到规则版
        risk_rules = pd.Series([""] * len(f), index=f.index)
        for name, fn in RULE_THRESHOLDS.items():
            mask = fn(f)
            risk_rules[mask] = risk_rules[mask] + name + ","
        out["risk_score"] = risk_rules.apply(lambda s: min(len(s.split(",")) * 20, 100) if s else 0)
        out["risk_level"] = pd.cut(out["risk_score"], [0, 30, 70, 100], labels=["低", "中", "高"], include_lowest=True)
        out["is_risk_user"] = (out["risk_score"] >= 50).astype(int)

    # 命中规则字符串（可解释）
    hit_rules = pd.Series([""] * len(f), index=f.index)
    for name, fn in RULE_THRESHOLDS.items():
        mask = fn(f)
        hit_rules[mask] = hit_rules[mask] + name + ","
    out["hit_rules"] = hit_rules.str.rstrip(",")

    # Top 贡献特征（简化版：取值最大的几个比率特征）
    top_cols = ["refund_rate_30d", "compensation_rate_30d", "cancel_rate_30d",
                "distinct_pay_tool_cnt_30d", "distinct_ip_cnt_30d"]
    out["top_features"] = f[top_cols].apply(
        lambda row: json.dumps({c: float(row[c]) for c in top_cols}, ensure_ascii=False), axis=1
    )

    out["model_version"] = version or "rules_only"
    out["update_time"] = datetime.now()

    # 写 mysql
    with engine.connect() as conn:
        conn.execute(f"DELETE FROM model_user_risk_score WHERE snapshot_dt = '{snapshot_dt.date()}'")
        conn.commit()
    out.to_sql("model_user_risk_score", engine, if_exists="append", index=False, chunksize=2000)
    print(f"[推理完成] {snapshot_dt.date()} {len(out)} 用户 高风险 {out['is_risk_user'].sum()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", default=None)
    args = parser.parse_args()
    snap = datetime.strptime(args.date, "%Y-%m-%d") if args.date else datetime.now() - timedelta(days=1)
    infer(snap)
