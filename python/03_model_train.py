"""
Leiden 风险用户识别 - 模型训练
LightGBM 二分类，预测 is_risk_user
"""
import os
import argparse
from datetime import datetime, timedelta
import pandas as pd
import numpy as np
import joblib
from sqlalchemy import create_engine
import lightgbm as lgb
from sklearn.model_selection import TimeSeriesSplit
from sklearn.metrics import average_precision_score, precision_recall_curve

MYSQL_URL = os.getenv("MYSQL_URL", "mysql+pymysql://root:root@localhost:3306/leiden?charset=utf8mb4")
MODEL_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "model")
os.makedirs(MODEL_DIR, exist_ok=True)

# 入模特征列
FEATURE_COLS = [
    # 规模
    "order_cnt_7d", "order_cnt_30d", "order_cnt_90d",
    "pay_ok_amount_7d", "pay_ok_amount_30d", "pay_ok_amount_90d",
    "cross_biz_cnt_7d", "cross_biz_cnt_30d", "cross_biz_cnt_90d",
    # 风险率
    "refund_rate_7d", "refund_rate_30d", "refund_rate_90d",
    "refund_amount_rate_7d", "refund_amount_rate_30d", "refund_amount_rate_90d",
    "cancel_rate_7d", "cancel_rate_30d", "cancel_rate_90d",
    "compensation_rate_7d", "compensation_rate_30d", "compensation_rate_90d",
    "compensation_amount_rate_7d", "compensation_amount_rate_30d", "compensation_amount_rate_90d",
    # 身份聚集
    "distinct_pay_tool_cnt_7d", "distinct_pay_tool_cnt_30d", "distinct_pay_tool_cnt_90d",
    "distinct_ip_cnt_7d", "distinct_ip_cnt_30d", "distinct_ip_cnt_90d",
    "distinct_contact_mob_cnt_7d", "distinct_contact_mob_cnt_30d", "distinct_contact_mob_cnt_90d",
    "distinct_passenger_cnt_7d", "distinct_passenger_cnt_30d", "distinct_passenger_cnt_90d",
    # 行为异常
    "min_interval_between_order_min_7d", "max_order_amount_30d", "night_order_cnt_30d",
    "same_flight_diff_passenger_cnt_30d", "same_passenger_diff_user_cnt_30d", "cross_biz_burst_cnt_7d",
    # 客诉
    "compensation_reject_cnt_30d", "compensation_auto_pay_rate_30d", "distinct_problem_type_cnt_30d",
]


def load_train(end_dt: datetime, lookback_days: int = 90):
    """加载训练数据：特征 + 标签，按 snapshot_dt 关联"""
    engine = create_engine(MYSQL_URL)
    start_dt = end_dt - timedelta(days=lookback_days)
    sql = f"""
    SELECT f.*, l.is_risk_user
    FROM feature_user_risk_profile f
    JOIN label_user_risk l USING(snapshot_dt, user_id)
    WHERE f.snapshot_dt BETWEEN '{start_dt.date()}' AND '{end_dt.date()}'
    """
    df = pd.read_sql(sql, engine)
    return df


def train(df: pd.DataFrame):
    df = df.sort_values("snapshot_dt")
    X = df[FEATURE_COLS].fillna(0).values
    y = df["is_risk_user"].values

    # 时序切分：最后 7 天做测试集
    test_cutoff = df["snapshot_dt"].max() - timedelta(days=7)
    test_idx = df["snapshot_dt"] > test_cutoff
    X_tr, X_te = X[~test_idx.values], X[test_idx.values]
    y_tr, y_te = y[~test_idx.values], y[test_idx.values]

    print(f"训练集 {len(X_tr)} 正样本 {y_tr.sum()} / 测试集 {len(X_te)} 正样本 {y_te.sum()}")

    if y_tr.sum() < 10:
        print("正样本太少，跳过监督训练，建议用规则版或异常检测")
        return None

    # 类别不均衡处理
    pos_w = (len(y_tr) - y_tr.sum()) / max(y_tr.sum(), 1)

    model = lgb.LGBMClassifier(
        n_estimators=400,
        learning_rate=0.05,
        num_leaves=31,
        min_child_samples=20,
        subsample=0.8,
        colsample_bytree=0.8,
        scale_pos_weight=pos_w,
        random_state=42,
    )
    model.fit(X_tr, y_tr,
              eval_set=[(X_te, y_te)],
              callbacks=[lgb.early_stopping(50), lgb.log_evaluation(50)])

    # 评估
    y_proba = model.predict_proba(X_te)[:, 1]
    pr_auc = average_precision_score(y_te, y_proba)
    print(f"PR-AUC = {pr_auc:.4f}")

    # 召回@1%FPR
    p, r, _ = precision_recall_curve(y_te, y_proba)
    print(f"最大召回 = {r.max():.4f}")

    # 特征重要性
    imp = pd.DataFrame({"feature": FEATURE_COLS, "importance": model.feature_importances_}) \
            .sort_values("importance", ascending=False)
    print("Top10 重要特征:")
    print(imp.head(10).to_string(index=False))

    # 保存
    version = datetime.now().strftime("%Y%m%d_%H%M")
    path = os.path.join(MODEL_DIR, f"lgb_{version}.pkl")
    joblib.dump({"model": model, "features": FEATURE_COLS, "version": version}, path)
    print(f"模型保存 {path}")
    return model, version


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--end-date", default=None)
    args = parser.parse_args()
    end = datetime.strptime(args.end_date, "%Y-%m-%d") if args.end_date else datetime.now() - timedelta(days=1)
    df = load_train(end)
    print(f"训练样本 {len(df)}")
    train(df)
