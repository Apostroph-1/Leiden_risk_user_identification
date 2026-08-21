"""
Leiden 项目 - 机票设备号风险分类（无监督 + 可解释）
方案见 docs/07_unsupervised_risk_model.md

流程：
  1. 数据加载 + 派生特征
  2. 规则预筛候选高危池
  3. Isolation Forest 异常检测
  4. K-Means 聚类细分风险类型
  5. SHAP + 决策树 surrogate 解释
  6. 风险分 + 标签输出
"""
import os
import sys
import json
import argparse
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler
from sklearn.tree import DecisionTreeClassifier, export_text, plot_tree
from sklearn.model_selection import train_test_split
import shap
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import joblib

# ---------- 路径 ----------
BASE = r"d:/Qunar_work/workbuddy_data/leiden"
DATA = os.path.join(BASE, "data")
OUT = os.path.join(BASE, "data", "model_output")
os.makedirs(OUT, exist_ok=True)

INPUT_CSV = os.path.join(DATA, "flight_feature_detail_8.19-90days.csv")

# ---------- 派生特征 ----------
def derive_features(df: pd.DataFrame) -> pd.DataFrame:
    """在原始字段基础上计算派生特征"""
    df = df.copy()
    tot = df["flight_total_order_cnt"].replace(0, np.nan)
    pay_ok_amt = df["flight_pay_ok_order_amount"].replace(0, np.nan)
    pay_ok_cnt = df["flight_pay_ok_order_cnt"].replace(0, np.nan)

    # 比率类
    df["refund_rate"] = df["flight_refund_order_cnt"] / tot
    df["refund_amount_rate"] = df["flight_refund_amount"] / pay_ok_amt
    df["comp_amount_rate"] = df["flight_comp_total_amount"] / pay_ok_amt
    df["cancel_rate"] = df["flight_cancel_order_cnt"] / tot
    df["gq_rate"] = df["flight_gq_order_cnt"] / tot
    df["ticket_success_rate"] = df["flight_ticket_success_order_cnt"] / tot
    df["voucher_order_rate"] = df["flight_voucher_order_cnt"] / tot
    df["scalper_rate"] = df["flight_scalper_cnt"] / tot
    df["intercept_rate"] = df["flight_intercept_cnt"] / tot

    # 单均聚集
    df["avg_order_amount"] = df["flight_pay_ok_order_amount"] / pay_ok_cnt
    df["user_per_order"] = df["flight_distinct_user_id_cnt"] / tot
    df["pay_tool_per_order"] = df["flight_distinct_pay_tool_cnt"] / tot
    df["ip_per_order"] = df["flight_distinct_ip_cnt"] / tot
    df["passenger_per_order"] = df["flight_uid_distinct_card_num_cnt"] / tot
    df["mobile_per_order"] = df["flight_uid_distinct_passenger_mobile_cnt"] / tot

    # 标记类
    df["is_short_refund"] = (df["flight_min_refund_pay_interval_sec"] <= 3600).astype(int)
    df["is_machine_refund"] = (
        (df["flight_cardinality_refund_pay_time_diff"] == 1) &
        (df["flight_refund_order_cnt"] >= 5)
    ).astype(int)
    df["is_night_heavy"] = (df["flight_night_order_cnt"] / tot >= 0.3).astype(int)
    df["is_multi_account"] = (df["flight_distinct_user_id_cnt"] >= 2).astype(int)
    df["is_multi_pay_tool"] = (df["flight_distinct_pay_tool_cnt"] >= 3).astype(int)
    df["is_multi_passenger"] = (df["flight_uid_distinct_card_num_cnt"] >= 5).astype(int)

    return df


# ---------- 入模特征清单 ----------
FEATURE_COLS = [
    # 规模
    "flight_total_order_cnt", "flight_pay_ok_order_cnt", "flight_pay_ok_order_amount", "flight_pay_tool_size",
    # 比率
    "refund_rate", "refund_amount_rate", "comp_amount_rate", "cancel_rate", "gq_rate",
    "ticket_success_rate", "voucher_order_rate", "scalper_rate", "intercept_rate",
    # 聚集
    "flight_distinct_user_id_cnt", "flight_distinct_username_cnt", "flight_distinct_mobile_cnt",
    "flight_distinct_email_cnt", "flight_distinct_pay_tool_cnt", "flight_distinct_ip_cnt",
    "flight_uid_distinct_card_num_cnt", "flight_uid_distinct_passenger_mobile_cnt",
    # 单价/比值
    "avg_order_amount", "user_per_order", "pay_tool_per_order", "ip_per_order",
    "passenger_per_order", "mobile_per_order",
    # 价格风险
    "flight_avg_discount", "flight_min_discount", "flight_bottom_price_order_cnt",
    "flight_add_price_sum", "flight_pricedepth_sum", "flight_voucher_sum",
    "flight_express_price_sum", "flight_service_fee_sum", "flight_exp_cut_sum",
    # 行为
    "flight_pre_day_avg", "flight_flight_size_avg", "flight_combine_order_cnt",
    "flight_distinct_dep_city_cnt", "flight_distinct_arr_city_cnt",
    "flight_night_order_cnt", "flight_weekend_order_cnt",
    # 时效
    "flight_min_refund_pay_interval_sec", "flight_max_refund_pay_interval_sec",
    "flight_avg_refund_pay_interval_sec", "flight_cardinality_refund_pay_time_diff",
    # 标记
    "is_short_refund", "is_machine_refund", "is_night_heavy",
    "is_multi_account", "is_multi_pay_tool", "is_multi_passenger",
    # 赔付
    "flight_comp_total_amount",
]


# ---------- 规则预筛 ----------
def rule_filter(df: pd.DataFrame) -> pd.DataFrame:
    """规则预筛候选高危池"""
    mask = (
        (df["refund_rate"] >= 0.3) |
        (df["flight_comp_total_amount"] >= 100) |
        (df["flight_distinct_user_id_cnt"] >= 2) |
        (df["flight_distinct_pay_tool_cnt"] >= 3) |
        (df["flight_scalper_cnt"] >= 1) |
        (df["flight_intercept_cnt"] >= 1) |
        (df["flight_uid_distinct_card_num_cnt"] >= 5) |
        (df["flight_distinct_ip_cnt"] >= 10) |
        (df["flight_night_order_cnt"] >= 3) |
        (df["is_short_refund"] == 1) |
        (df["is_machine_refund"] == 1) |
        (df["flight_comp_total_amount"] >= 500)
    )
    return df[mask].copy()


# ---------- 缺失值 ----------
def fill_missing(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    for c in FEATURE_COLS:
        if c in df.columns:
            if c in ("flight_min_refund_pay_interval_sec", "flight_max_refund_pay_interval_sec",
                     "flight_avg_refund_pay_interval_sec"):
                df[c] = df[c].fillna(999999)  # 无退款视为"不接近异常"
            elif c in ("flight_avg_discount", "flight_min_discount", "flight_pre_day_avg",
                       "flight_flight_size_avg"):
                df[c] = df[c].fillna(df[c].median())
            else:
                df[c] = df[c].fillna(0)
    return df


# ---------- 主流程 ----------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", type=int, default=None, help="可选：只取前N行调试")
    args = parser.parse_args()

    # ---------- 1. 加载数据 ----------
    print(f"[1/7] 加载数据 {INPUT_CSV}")
    nrows = args.sample if args.sample else None
    df = pd.read_csv(INPUT_CSV, nrows=nrows)
    print(f"  原始行数 {len(df)}")

    # 派生特征
    df = derive_features(df)
    df = fill_missing(df)
    df.to_csv(os.path.join(OUT, "df_with_features.csv"), index=False)
    print(f"  派生特征后保存 df_with_features.csv ({len(df)} 行)")

    # ---------- 2. 规则预筛 ----------
    print(f"[2/7] 规则预筛候选高危池")
    cand = rule_filter(df)
    print(f"  候选高危设备 {len(cand)} ({len(cand)/len(df)*100:.1f}%)")
    cand.to_csv(os.path.join(OUT, "candidate_devices.csv"), index=False)

    if len(cand) < 100:
        print("  候选样本太少，跳过建模")
        return

    # ---------- 3. Isolation Forest ----------
    print(f"[3/7] Isolation Forest 异常检测")
    X = cand[FEATURE_COLS].values
    iforest = IsolationForest(n_estimators=200, contamination=0.1, random_state=42, n_jobs=-1)
    cand["iforest_label"] = iforest.fit_predict(X)  # -1 异常, 1 正常
    cand["iforest_score"] = -iforest.score_samples(X)  # 越大越异常
    cand["iforest_anomaly"] = (cand["iforest_label"] == -1).astype(int)
    n_anom = cand["iforest_anomaly"].sum()
    print(f"  异常设备 {n_anom} ({n_anom/len(cand)*100:.1f}% of 候选)")
    joblib.dump(iforest, os.path.join(OUT, "iforest.pkl"))

    # ---------- 4. K-Means 聚类（仅对异常设备） ----------
    print(f"[4/7] K-Means 聚类细分")
    anom = cand[cand["iforest_anomaly"] == 1].copy()
    if len(anom) < 50:
        print("  异常样本太少，跳过聚类")
        anom["cluster"] = 0
    else:
        Xa = anom[FEATURE_COLS].values
        scaler = StandardScaler()
        Xa_s = scaler.fit_transform(Xa)
        # 选 K：4-8，按轮廓系数
        best_k, best_s = 4, -1
        for k in range(4, 9):
            km = KMeans(n_clusters=k, random_state=42, n_init=10)
            labels = km.fit_predict(Xa_s)
            s = silhouette_score(Xa_s, labels, sample_size=min(5000, len(Xa_s)))
            print(f"  k={k} silhouette={s:.4f}")
            if s > best_s:
                best_k, best_s = k, s
        print(f"  选 k={best_k} (silhouette={best_s:.4f})")
        km = KMeans(n_clusters=best_k, random_state=42, n_init=10)
        anom["cluster"] = km.fit_predict(Xa_s)
        joblib.dump(scaler, os.path.join(OUT, "kmeans_scaler.pkl"))
        joblib.dump(km, os.path.join(OUT, "kmeans.pkl"))

    # 簇画像
    if "cluster" in anom.columns:
        cluster_profile = anom.groupby("cluster")[FEATURE_COLS].mean()
        cluster_profile["cluster_size"] = anom.groupby("cluster").size()
        cluster_profile.to_csv(os.path.join(OUT, "cluster_profile.csv"))
        print(f"  簇画像保存 cluster_profile.csv")

    # ---------- 5. SHAP 解释 ----------
    print(f"[5/7] SHAP 解释")
    try:
        # SHAP 对 IsolationForest 用 TreeExplainer
        explainer = shap.TreeExplainer(iforest)
        # 采样以加速（SHAP 对 50K+ 样本很慢）
        sample_n = min(2000, len(cand))
        Xs = cand[FEATURE_COLS].iloc[:sample_n].values
        sv = explainer.shap_values(Xs)
        # 全局重要性
        imp = pd.DataFrame({"feature": FEATURE_COLS, "shap_mean_abs": np.abs(sv).mean(axis=0)})
        imp = imp.sort_values("shap_mean_abs", ascending=False)
        imp.to_csv(os.path.join(OUT, "shap_global_importance.csv"), index=False)
        print(f"  全局重要性 Top10:")
        print(imp.head(10).to_string(index=False))
        # 局部解释 top10 异常设备
        top_anom_idx = cand.sort_values("iforest_score", ascending=False).head(10).index
        top_in_X = [list(cand.index).index(i) for i in top_anom_idx]
        shap_df = pd.DataFrame(sv[top_in_X], columns=FEATURE_COLS)
        shap_df.insert(0, "device_id", cand.loc[top_anom_idx, "device_id"].values)
        shap_df.insert(1, "iforest_score", cand.loc[top_anom_idx, "iforest_score"].values)
        shap_df.to_csv(os.path.join(OUT, "shap_top10_anomaly.csv"), index=False)
        print(f"  Top10 异常设备 SHAP 保存 shap_top10_anomaly.csv")
    except Exception as e:
        print(f"  SHAP 失败: {e}")

    # ---------- 6. 决策树 surrogate ----------
    print(f"[6/7] 决策树 surrogate 全局解释")
    y = cand["iforest_anomaly"].values
    dt = DecisionTreeClassifier(max_depth=4, random_state=42, min_samples_leaf=50)
    dt.fit(X, y)
    acc = dt.score(X, y)
    print(f"  决策树拟合准确率 {acc:.4f}")
    # 文本规则
    rules_txt = export_text(dt, feature_names=FEATURE_COLS, max_depth=4)
    with open(os.path.join(OUT, "tree_rules.txt"), "w", encoding="utf-8") as f:
        f.write(f"决策树 surrogate 拟合准确率: {acc:.4f}\n\n")
        f.write(rules_txt)
    # 可视化
    try:
        plt.figure(figsize=(24, 12))
        plot_tree(dt, feature_names=FEATURE_COLS, class_names=["正常", "异常"],
                  filled=True, fontsize=8, max_depth=4)
        plt.title("Decision Tree Surrogate for Isolation Forest")
        plt.tight_layout()
        plt.savefig(os.path.join(OUT, "tree_rules.png"), dpi=120)
        plt.close()
        print(f"  决策树图保存 tree_rules.png")
    except Exception as e:
        print(f"  决策树可视化失败: {e}")
    joblib.dump(dt, os.path.join(OUT, "tree_surrogate.pkl"))

    # ---------- 7. 风险分 + 标签输出 ----------
    print(f"[7/7] 风险分 + 标签输出")
    # 风险分：iforest_score 归一化到 0-100
    score = cand["iforest_score"].values
    if score.max() > score.min():
        cand["risk_score_raw"] = (score - score.min()) / (score.max() - score.min())
    else:
        cand["risk_score_raw"] = 0
    cand["risk_score"] = (cand["risk_score_raw"] * 100).round(2)
    cand["risk_level"] = pd.cut(cand["risk_score"], [0, 30, 70, 100.01],
                                labels=["低", "中", "高"], include_lowest=True)
    # 合并簇标签
    if "cluster" in anom.columns:
        cand = cand.merge(anom[["device_id", "cluster"]].rename(columns={"cluster": "risk_cluster"}),
                           on="device_id", how="left")
        cand["risk_cluster"] = cand["risk_cluster"].fillna(-1).astype(int)
    else:
        cand["risk_cluster"] = -1

    out_cols = ["device_id", "risk_score", "risk_level", "risk_cluster",
                "iforest_anomaly", "iforest_score",
                "flight_total_order_cnt", "flight_refund_order_cnt", "flight_comp_total_amount",
                "flight_distinct_user_id_cnt", "flight_distinct_pay_tool_cnt",
                "flight_scalper_cnt", "flight_intercept_cnt",
                "refund_rate", "comp_amount_rate", "is_multi_account", "is_machine_refund"]
    out_cols = [c for c in out_cols if c in cand.columns]
    result = cand[out_cols].sort_values("risk_score", ascending=False)
    result.to_csv(os.path.join(OUT, "device_risk_score.csv"), index=False)
    print(f"  风险分输出 device_risk_score.csv ({len(result)} 设备)")
    print(f"  高风险: {(result['risk_level']=='高').sum()}  中风险: {(result['risk_level']=='中').sum()}  低风险: {(result['risk_level']=='低').sum()}")
    print(f"\n[完成] 全部输出在 {OUT}")


if __name__ == "__main__":
    main()
