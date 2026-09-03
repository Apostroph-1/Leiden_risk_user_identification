# 12_prev_period_stratify — 上周期全量 base 的分层与高危名单导出
# 输入: data/26.05.29_base.csv（T-180d~T-90d 全量设备宽表）
# 输出: data/model_output/26.05.29_device_risk_score.csv（带日期前缀，供线上跑 detail 用）
# 逻辑: 复用 02 的规则+投票（轻量版：规则打标 + iForest，不训监督模型——上周期只需"中高危名单"用于导 detail）
import os, time
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest

BASE = "/app"
DATA = os.path.join(BASE, "data")
OUT  = os.path.join(BASE, "data", "model_output")

PREV_BASE = os.path.join(DATA, "26.05.29_base.csv")
PREFIX = "26.05.29"
print(f"[上周期分层] {PREV_BASE}")
t0 = time.time()

df = pd.read_csv(PREV_BASE, dtype=str)
STRING_COLS = {"device_id","flight_distinct_user_id","flight_distinct_username","flight_pay_tool_detail","flight_uid_card_info","flight_passenger_mobile_info"}
for col in df.columns:
    if col not in STRING_COLS:
        df[col] = pd.to_numeric(df[col], errors="coerce")
print(f"  {len(df)} 设备, 耗时 {time.time()-t0:.1f}s")

# === 规则打标（与 02 同口径，v2 退款修正）===
tot = df["flight_total_order_cnt"].replace(0, np.nan)
_roc = df["flight_refund_order_cnt"].fillna(0)
_has_trace = df["flight_min_refund_pay_interval_sec"].notna().astype(int)
df["_refund_cnt_fixed"] = _roc + ((_roc == 0) & (_has_trace == 1)).astype(int)
df["refund_rate"] = df["_refund_cnt_fixed"] / tot
df["is_short_refund_strong"] = (df["flight_min_refund_pay_interval_sec"] <= 600).astype(int)
df["is_multi_account"] = (df["flight_distinct_user_id_cnt"] >= 2).astype(int)
df["is_multi_pay_tool"] = (df["flight_distinct_pay_tool_cnt"] >= 3).astype(int)
df["is_multi_passenger"] = (df["flight_uid_distinct_card_num_cnt"] >= 5).astype(int)
df["is_scalper"] = (df["flight_scalper_cnt"] >= 1).astype(int)
df["is_machine_refund"] = ((df["_refund_cnt_fixed"] >= 3) & (df["refund_rate"] > 0.5)).astype(int)
df["is_night_heavy"] = ((df["flight_night_order_cnt"] / tot) >= 0.5).astype(int)
df["rule_hit_cnt"] = (df["is_short_refund_strong"] + df["is_multi_account"] + df["is_multi_pay_tool"]
                       + df["is_multi_passenger"] + df["is_machine_refund"] + df["is_night_heavy"])

# === iForest 异常分（数值特征）===
feat_cols = [c for c in ["flight_total_order_cnt","flight_pay_ok_order_amount","refund_rate","comp_amount_rate",
             "flight_distinct_user_id_cnt","flight_distinct_pay_tool_cnt","flight_distinct_ip_cnt",
             "flight_uid_distinct_card_num_cnt","flight_night_order_cnt","flight_scalper_cnt",
             "flight_intercept_cnt","flight_comp_total_amount"] if c in df.columns]
X = df[feat_cols].fillna(0).replace([np.inf,-np.inf], 0)
iso = IsolationForest(n_estimators=100, random_state=42, n_jobs=-1)
df["iforest_anomaly"] = (iso.fit_predict(X) == -1).astype(int)

# === 中高危名单（与 02 分层一致的口径：投票+规则）===
vote = df["iforest_anomaly"] + df["is_scalper"]  # 轻量投票（iForest + 黄牛标记）
df["vote_anomaly_cnt"] = vote
df["vote_total"] = 2
df["risk_level"] = np.where((df["vote_anomaly_cnt"] >= 2) & (df["rule_hit_cnt"] >= 2), "高风险",
                    np.where((df["vote_anomaly_cnt"] >= 1) & (df["rule_hit_cnt"] >= 1), "中风险",
                    np.where((df["rule_hit_cnt"] >= 1) | (df["vote_anomaly_cnt"] >= 1), "疑似风险", "普通用户")))
mid_high = df[(df["rule_hit_cnt"] >= 1) | (df["vote_anomaly_cnt"] >= 1)].copy()

n_midhigh = (df["risk_level"].isin(["高风险","中风险"])).sum()
print(f"  中高危设备: {n_midhigh} / {len(df)}")
print(f"  高风险: {(df['risk_level']=='高风险').sum()}, 中风险: {(df['risk_level']=='中风险').sum()}")

# === 输出（带日期前缀）===
out_cols = ["device_id","risk_level","rule_hit_cnt","vote_anomaly_cnt","vote_total",
            "refund_rate","is_short_refund_strong","is_multi_account","is_multi_pay_tool",
            "is_multi_passenger","is_scalper","is_machine_refund","is_night_heavy",
            "flight_total_order_cnt","flight_refund_order_cnt","flight_comp_total_amount"]
out_path = os.path.join(OUT, f"{PREFIX}_device_risk_score.csv")
df[out_cols].to_csv(out_path, index=False, encoding="utf-8-sig")
# 中高危名单单独一份（上传线上 temp 表用）
mh_path = os.path.join(OUT, f"{PREFIX}_midhigh_devices.csv")
mid_high[["device_id","risk_level","rule_hit_cnt"]].to_csv(mh_path, index=False, encoding="utf-8-sig")
print(f"  输出: {out_path}")
print(f"  中高危名单: {mh_path} ({n_midhigh} 台)")
print(f"  耗时 {time.time()-t0:.1f}s")
