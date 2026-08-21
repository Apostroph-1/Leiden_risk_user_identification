"""
Leiden 项目 - 多模型对比 + 4 级风险分层
方案见 docs/08_multi_model_stratification.md

模型清单：
  无监督：Isolation Forest, One-Class SVM (线性), LOF
  监督（伪标签）：XGBoost, LightGBM, Random Forest
  可解释辅助：决策树 surrogate + SHAP

4 级分层：
  - 高风险 High     ：多模型共识异常 + 强规则命中
  - 中风险 Medium   ：多模型多数异常 + 弱规则
  - 疑似风险 Suspect：少量模型异常或仅规则命中
  - 普通用户 Normal ：无异常
"""
import os
import argparse
import warnings
warnings.filterwarnings("ignore")
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest, RandomForestClassifier
from sklearn.neighbors import LocalOutlierFactor
from sklearn.svm import OneClassSVM
from sklearn.preprocessing import StandardScaler, RobustScaler
from sklearn.tree import DecisionTreeClassifier, export_text, plot_tree
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, roc_auc_score, precision_recall_curve, average_precision_score
import shap
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns
import joblib

try:
    import xgboost as xgb
    HAS_XGB = True
except Exception:
    HAS_XGB = False
try:
    import lightgbm as lgb
    HAS_LGB = True
except Exception:
    HAS_LGB = False

BASE = r"d:/Qunar_work/workbuddy_data/leiden"
DATA = os.path.join(BASE, "data")
OUT = os.path.join(BASE, "data", "model_output")
os.makedirs(OUT, exist_ok=True)

INPUT_CSV = os.path.join(DATA, "flight_feature_detail_8.19-90days.csv")

# ---------- 派生特征 ----------
def derive_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    tot = df["flight_total_order_cnt"].replace(0, np.nan)
    pay_ok_amt = df["flight_pay_ok_order_amount"].replace(0, np.nan)
    pay_ok_cnt = df["flight_pay_ok_order_cnt"].replace(0, np.nan)

    df["refund_rate"] = df["flight_refund_order_cnt"] / tot
    df["refund_amount_rate"] = df["flight_refund_amount"] / pay_ok_amt
    df["comp_amount_rate"] = df["flight_comp_total_amount"] / pay_ok_amt
    df["cancel_rate"] = df["flight_cancel_order_cnt"] / tot
    df["gq_rate"] = df["flight_gq_order_cnt"] / tot
    df["ticket_success_rate"] = df["flight_ticket_success_order_cnt"] / tot
    df["voucher_order_rate"] = df["flight_voucher_order_cnt"] / tot
    df["scalper_rate"] = df["flight_scalper_cnt"] / tot
    df["intercept_rate"] = df["flight_intercept_cnt"] / tot
    df["avg_order_amount"] = df["flight_pay_ok_order_amount"] / pay_ok_cnt
    df["user_per_order"] = df["flight_distinct_user_id_cnt"] / tot
    df["pay_tool_per_order"] = df["flight_distinct_pay_tool_cnt"] / tot
    df["ip_per_order"] = df["flight_distinct_ip_cnt"] / tot
    df["passenger_per_order"] = df["flight_uid_distinct_card_num_cnt"] / tot
    df["mobile_per_order"] = df["flight_uid_distinct_passenger_mobile_cnt"] / tot
    df["is_short_refund"] = (df["flight_min_refund_pay_interval_sec"] <= 3600).astype(int)
    df["is_machine_refund"] = ((df["flight_cardinality_refund_pay_time_diff"] == 1) & (df["flight_refund_order_cnt"] >= 5)).astype(int)
    df["is_night_heavy"] = (df["flight_night_order_cnt"] / tot >= 0.3).astype(int)
    df["is_multi_account"] = (df["flight_distinct_user_id_cnt"] >= 2).astype(int)
    df["is_multi_pay_tool"] = (df["flight_distinct_pay_tool_cnt"] >= 3).astype(int)
    df["is_multi_passenger"] = (df["flight_uid_distinct_card_num_cnt"] >= 5).astype(int)
    return df


FEATURE_COLS = [
    "flight_total_order_cnt", "flight_pay_ok_order_cnt", "flight_pay_ok_order_amount", "flight_pay_tool_size",
    "refund_rate", "refund_amount_rate", "comp_amount_rate", "cancel_rate", "gq_rate",
    "ticket_success_rate", "voucher_order_rate", "scalper_rate", "intercept_rate",
    "flight_distinct_user_id_cnt", "flight_distinct_username_cnt", "flight_distinct_mobile_cnt",
    "flight_distinct_email_cnt", "flight_distinct_pay_tool_cnt", "flight_distinct_ip_cnt",
    "flight_uid_distinct_card_num_cnt", "flight_uid_distinct_passenger_mobile_cnt",
    "avg_order_amount", "user_per_order", "pay_tool_per_order", "ip_per_order",
    "passenger_per_order", "mobile_per_order",
    "flight_avg_discount", "flight_min_discount", "flight_bottom_price_order_cnt",
    "flight_add_price_sum", "flight_pricedepth_sum", "flight_voucher_sum",
    "flight_express_price_sum", "flight_service_fee_sum", "flight_exp_cut_sum",
    "flight_pre_day_avg", "flight_flight_size_avg", "flight_combine_order_cnt",
    "flight_distinct_dep_city_cnt", "flight_distinct_arr_city_cnt",
    "flight_night_order_cnt", "flight_weekend_order_cnt",
    "flight_min_refund_pay_interval_sec", "flight_max_refund_pay_interval_sec",
    "flight_avg_refund_pay_interval_sec", "flight_cardinality_refund_pay_time_diff",
    "is_short_refund", "is_machine_refund", "is_night_heavy",
    "is_multi_account", "is_multi_pay_tool", "is_multi_passenger",
    "flight_comp_total_amount",
]


def fill_missing(df):
    df = df.copy()
    for c in FEATURE_COLS:
        if c in df.columns:
            if c in ("flight_min_refund_pay_interval_sec", "flight_max_refund_pay_interval_sec",
                     "flight_avg_refund_pay_interval_sec"):
                df[c] = df[c].fillna(999999)
            elif c in ("flight_avg_discount", "flight_min_discount", "flight_pre_day_avg", "flight_flight_size_avg"):
                df[c] = df[c].fillna(df[c].median())
            else:
                df[c] = df[c].fillna(0)
    return df


# ---------- 伪标签生成 ----------
def gen_pseudo_labels(df: pd.DataFrame) -> pd.DataFrame:
    """用强规则生成伪标签
    1=高置信异常，0=正常。中间归为未标记，不参与监督训练。
    """
    df = df.copy()
    # 高置信异常（强规则）
    strong = (
        (df["refund_rate"] >= 0.5) & (df["flight_refund_order_cnt"] >= 5)
    ) | (
        (df["flight_comp_total_amount"] >= 500) & (df["flight_distinct_user_id_cnt"] >= 2)
    ) | (
        df["flight_scalper_cnt"] >= 1
    ) | (
        df["is_machine_refund"] == 1
    ) | (
        (df["flight_distinct_user_id_cnt"] >= 8) & (df["flight_total_order_cnt"] >= 20)
    ) | (
        df["flight_intercept_cnt"] >= 3
    )

    # 高置信正常（明显无异常）
    normal = (
        (df["flight_refund_order_cnt"] == 0) &
        (df["flight_comp_total_amount"] == 0) &
        (df["flight_distinct_user_id_cnt"] == 1) &
        (df["flight_scalper_cnt"] == 0) &
        (df["flight_intercept_cnt"] == 0) &
        (df["flight_distinct_pay_tool_cnt"] <= 2) &
        (df["flight_uid_distinct_card_num_cnt"] <= 2)
    )

    df["pseudo_label"] = -1  # 未标记
    df.loc[strong, "pseudo_label"] = 1
    df.loc[normal, "pseudo_label"] = 0
    return df


# ---------- 主流程 ----------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", type=int, default=None)
    args = parser.parse_args()

    print(f"[1/9] 加载数据")
    nrows = args.sample if args.sample else None
    df = pd.read_csv(INPUT_CSV, nrows=nrows)
    print(f"  原始 {len(df)} 行")
    df = derive_features(df)
    df = fill_missing(df)
    df = gen_pseudo_labels(df)
    n_pos = (df["pseudo_label"] == 1).sum()
    n_neg = (df["pseudo_label"] == 0).sum()
    n_unk = (df["pseudo_label"] == -1).sum()
    print(f"  伪标签: 异常={n_pos} 正常={n_neg} 未标记={n_unk}")

    X_all = df[FEATURE_COLS].values

    # 规则命中数（用作分层依据）
    rule_cols = ["is_short_refund","is_machine_refund","is_night_heavy",
                 "is_multi_account","is_multi_pay_tool","is_multi_passenger"]
    df["rule_hit_cnt"] = df[rule_cols].sum(axis=1)

    # ---------- 2. Isolation Forest ----------
    print(f"[2/9] Isolation Forest")
    iforest = IsolationForest(n_estimators=200, contamination=0.1, random_state=42, n_jobs=-1)
    iforest.fit(X_all)
    df["iforest_label"] = iforest.predict(X_all)  # -1 异常
    df["iforest_score"] = -iforest.score_samples(X_all)  # 越大越异常
    df["iforest_anomaly"] = (df["iforest_label"] == -1).astype(int)
    print(f"  异常 {df['iforest_anomaly'].sum()}")

    # ---------- 3. One-Class SVM ----------
    print(f"[3/9] One-Class SVM（线性采样加速）")
    # SVM 慢，采样训练 + 用 RBF 近似
    sample_n = min(20000, len(df))
    sample_idx = np.random.RandomState(42).choice(len(df), sample_n, replace=False)
    scaler_ocsvm = StandardScaler()
    Xs = scaler_ocsvm.fit_transform(X_all[sample_idx])
    try:
        ocsvm = OneClassSVM(kernel="rbf", nu=0.1, gamma="scale")
        ocsvm.fit(Xs)
        # 对全量打分（用支持向量近似）
        df["ocsvm_score"] = ocsvm.decision_function(scaler_ocsvm.transform(X_all))
        df["ocsvm_anomaly"] = (ocsvm.predict(scaler_ocsvm.transform(X_all)) == -1).astype(int)
        print(f"  异常 {df['ocsvm_anomaly'].sum()}")
    except Exception as e:
        print(f"  OCSVM 失败: {e}")
        df["ocsvm_score"] = 0
        df["ocsvm_anomaly"] = 0

    # ---------- 4. LOF ----------
    print(f"[4/9] Local Outlier Factor")
    # LOF 默认无 predict，需 novelty=True
    sample_n = min(30000, len(df))
    sample_idx = np.random.RandomState(42).choice(len(df), sample_n, replace=False)
    scaler_lof = StandardScaler()
    Xs = scaler_lof.fit_transform(X_all[sample_idx])
    try:
        # n_neighbors: 50 (默认20偏小, 30K采样下50更稳定)
        lof = LocalOutlierFactor(n_neighbors=50, novelty=True, n_jobs=-1)
        lof.fit(Xs)
        df["lof_score"] = -lof.score_samples(scaler_lof.transform(X_all))  # 负异常分越大越异常
        df["lof_anomaly"] = (lof.predict(scaler_lof.transform(X_all)) == -1).astype(int)
        print(f"  异常 {df['lof_anomaly'].sum()}")
    except Exception as e:
        print(f"  LOF 失败: {e}")
        df["lof_score"] = 0
        df["lof_anomaly"] = 0

    # ---------- 5. XGBoost / LightGBM 监督（伪标签） ----------
    print(f"[5/9] 监督模型（基于伪标签）")
    mask = df["pseudo_label"] != -1
    df_lab = df[mask].copy()
    X_lab = df_lab[FEATURE_COLS].values
    y_lab = df_lab["pseudo_label"].values
    X_tr, X_te, y_tr, y_te = train_test_split(X_lab, y_lab, test_size=0.2, random_state=42, stratify=y_lab)
    print(f"  训练 {len(X_tr)} (正{y_tr.sum()}) / 测试 {len(X_te)} (正{y_te.sum()})")

    # XGBoost
    pos_w = (len(y_tr) - y_tr.sum()) / max(y_tr.sum(), 1)
    if HAS_XGB:
        print(f"  -> XGBoost")
        xgb_model = xgb.XGBClassifier(
            n_estimators=300, max_depth=6, learning_rate=0.05,
            subsample=0.8, colsample_bytree=0.8,
            scale_pos_weight=pos_w, n_jobs=-1, random_state=42,
            eval_metric="aucpr", verbosity=0
        )
        xgb_model.fit(X_tr, y_tr)
        df["xgb_prob"] = xgb_model.predict_proba(X_all)[:, 1]
        df["xgb_pred"] = (df["xgb_prob"] >= 0.5).astype(int)
        # 评估
        y_pred = xgb_model.predict(X_te)
        y_proba = xgb_model.predict_proba(X_te)[:, 1]
        ap = average_precision_score(y_te, y_proba)
        print(f"     XGBoost 测试集 Average Precision = {ap:.4f}")
        print(classification_report(y_te, y_pred, target_names=["正常", "异常"], digits=3))
        joblib.dump(xgb_model, os.path.join(OUT, "xgb.pkl"))

    # LightGBM
    if HAS_LGB:
        print(f"  -> LightGBM")
        lgb_model = lgb.LGBMClassifier(
            n_estimators=300, num_leaves=31, learning_rate=0.05,
            subsample=0.8, colsample_bytree=0.8,
            scale_pos_weight=pos_w, n_jobs=-1, random_state=42, verbose=-1
        )
        lgb_model.fit(X_tr, y_tr)
        df["lgb_prob"] = lgb_model.predict_proba(X_all)[:, 1]
        df["lgb_pred"] = (df["lgb_prob"] >= 0.5).astype(int)
        y_pred = lgb_model.predict(X_te)
        y_proba = lgb_model.predict_proba(X_te)[:, 1]
        ap = average_precision_score(y_te, y_proba)
        print(f"     LightGBM 测试集 Average Precision = {ap:.4f}")
        print(classification_report(y_te, y_pred, target_names=["正常", "异常"], digits=3))
        joblib.dump(lgb_model, os.path.join(OUT, "lgb.pkl"))

    # RandomForest
    print(f"  -> RandomForest")
    rf = RandomForestClassifier(n_estimators=200, max_depth=10, n_jobs=-1, random_state=42, class_weight="balanced")
    rf.fit(X_tr, y_tr)
    df["rf_prob"] = rf.predict_proba(X_all)[:, 1]
    df["rf_pred"] = (df["rf_prob"] >= 0.5).astype(int)
    y_pred = rf.predict(X_te)
    y_proba = rf.predict_proba(X_te)[:, 1]
    ap = average_precision_score(y_te, y_proba)
    print(f"     RF 测试集 Average Precision = {ap:.4f}")
    print(classification_report(y_te, y_pred, target_names=["正常", "异常"], digits=3))
    joblib.dump(rf, os.path.join(OUT, "rf.pkl"))

    # ---------- 6. 多模型投票 ----------
    print(f"[6/9] 多模型投票")
    anomaly_cols = ["iforest_anomaly", "ocsvm_anomaly", "lof_anomaly"]
    pred_cols = ["xgb_pred", "lgb_pred", "rf_pred"]
    vote_cols = [c for c in anomaly_cols + pred_cols if c in df.columns]
    df["vote_anomaly_cnt"] = df[vote_cols].sum(axis=1)
    df["vote_total"] = len(vote_cols)
    df["vote_rate"] = df["vote_anomaly_cnt"] / df["vote_total"]
    print(f"  投票模型数 {len(vote_cols)}")
    print(f"  投票分布:")
    print(df["vote_anomaly_cnt"].value_counts().sort_index().to_string())

    # ---------- 7. 4 级分层 ----------
    print(f"[7/9] 4 级风险分层")
    def stratify(row):
        vote = row["vote_anomaly_cnt"]
        total = row["vote_total"]
        rule_hits = row["rule_hit_cnt"]
        # 高风险：多数模型判定异常 + 规则命中
        if vote >= total * 0.6 and rule_hits >= 2:
            return "高风险"
        # 中风险：少数模型异常 + 强规则
        if vote >= 2 and rule_hits >= 1:
            return "中风险"
        # 疑似风险：少量异常或仅规则命中
        if vote >= 1 or rule_hits >= 1:
            return "疑似风险"
        return "普通用户"
    df["risk_level"] = df.apply(stratify, axis=1)
    print(f"  分层结果:")
    print(df["risk_level"].value_counts().to_string())

    # ---------- 8. 可解释：SHAP + 决策树 surrogate ----------
    print(f"[8/9] 可解释：SHAP + 决策树 surrogate")
    # SHAP（对 XGBoost 或 LightGBM）
    try:
        best_model = None
        best_name = ""
        if HAS_XGB:
            best_model, best_name = xgb_model, "XGBoost"
        elif HAS_LGB:
            best_model, best_name = lgb_model, "LightGBM"
        if best_model is not None:
            print(f"  SHAP 解释 {best_name}")
            sample_n = min(3000, len(df))
            Xs = df[FEATURE_COLS].iloc[:sample_n].values
            explainer = shap.TreeExplainer(best_model)
            sv = explainer.shap_values(Xs)
            # 二分类 shap 取正类
            if isinstance(sv, list):
                sv = sv[1]
            imp = pd.DataFrame({"feature": FEATURE_COLS, "shap_mean_abs": np.abs(sv).mean(axis=0)})
            imp = imp.sort_values("shap_mean_abs", ascending=False).reset_index(drop=True)
            imp.to_csv(os.path.join(OUT, "shap_global_importance.csv"), index=False)
            print(f"  SHAP Top10:")
            print(imp.head(10).to_string(index=False))
            # 局部 top10
            top_idx = df.iloc[:sample_n].sort_values("xgb_prob" if HAS_XGB else "lgb_prob", ascending=False).head(10).index
            top_pos = list(top_idx)
            shap_df = pd.DataFrame(sv[top_pos], columns=FEATURE_COLS)
            shap_df.insert(0, "device_id", df.loc[top_idx, "device_id"].values)
            shap_df.insert(1, "risk_level", df.loc[top_idx, "risk_level"].values)
            shap_df.to_csv(os.path.join(OUT, "shap_top10_anomaly.csv"), index=False)
            # SHAP summary plot
            shap.summary_plot(sv, features=df[FEATURE_COLS].iloc[:sample_n],
                              feature_names=FEATURE_COLS, show=False, max_display=15)
            plt.title(f"SHAP Summary - {best_name}")
            plt.tight_layout()
            plt.savefig(os.path.join(OUT, "shap_summary.png"), dpi=120, bbox_inches="tight")
            plt.close()
    except Exception as e:
        print(f"  SHAP 失败: {e}")

    # 决策树 surrogate（解释 vote_rate）
    try:
        print(f"  决策树 surrogate 解释 vote_rate")
        y_sur = (df["vote_anomaly_cnt"] >= df["vote_total"] * 0.5).astype(int)
        dt = DecisionTreeClassifier(max_depth=4, random_state=42, min_samples_leaf=50)
        dt.fit(X_all, y_sur)
        acc = dt.score(X_all, y_sur)
        print(f"  决策树拟合准确率 {acc:.4f}")
        rules_txt = export_text(dt, feature_names=FEATURE_COLS, max_depth=4)
        with open(os.path.join(OUT, "tree_rules.txt"), "w", encoding="utf-8") as f:
            f.write(f"决策树 surrogate 拟合准确率: {acc:.4f}\n\n")
            f.write(rules_txt)
        plt.figure(figsize=(24, 12))
        plot_tree(dt, feature_names=FEATURE_COLS, class_names=["正常", "异常"],
                  filled=True, fontsize=8, max_depth=4)
        plt.title("Decision Tree Surrogate for Multi-Model Vote")
        plt.tight_layout()
        plt.savefig(os.path.join(OUT, "tree_rules.png"), dpi=120)
        plt.close()
        joblib.dump(dt, os.path.join(OUT, "tree_surrogate.pkl"))
    except Exception as e:
        print(f"  决策树 surrogate 失败: {e}")

    # ---------- 9. 输出 ----------
    print(f"[9/9] 输出")
    out_cols = ["device_id", "risk_level", "vote_anomaly_cnt", "vote_total",
                "iforest_score", "iforest_anomaly", "ocsvm_score", "ocsvm_anomaly",
                "lof_score", "lof_anomaly"]
    if HAS_XGB:
        out_cols += ["xgb_prob", "xgb_pred"]
    if HAS_LGB:
        out_cols += ["lgb_prob", "lgb_pred"]
    out_cols += ["rf_prob", "rf_pred", "rule_hit_cnt",
                 "flight_total_order_cnt", "flight_refund_order_cnt",
                 "flight_comp_total_amount", "flight_distinct_user_id_cnt",
                 "flight_distinct_pay_tool_cnt", "flight_scalper_cnt",
                 "flight_intercept_cnt", "refund_rate", "comp_amount_rate",
                 "is_multi_account", "is_machine_refund", "pseudo_label"]
    out_cols = [c for c in out_cols if c in df.columns]
    result = df[out_cols].sort_values(
        ["risk_level", "vote_anomaly_cnt"],
        ascending=[True, False]
    )
    # 排序：高风险在前
    level_order = {"高风险": 0, "中风险": 1, "疑似风险": 2, "普通用户": 3}
    result["level_order"] = result["risk_level"].map(level_order)
    result = result.sort_values(["level_order", "vote_anomaly_cnt"], ascending=[True, False])
    result.drop(columns=["level_order"]).to_csv(os.path.join(OUT, "device_risk_score.csv"), index=False)

    # 模型对比报告
    with open(os.path.join(OUT, "model_comparison.txt"), "w", encoding="utf-8") as f:
        f.write("=" * 60 + "\n")
        f.write("多模型对比报告\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"总样本数: {len(df)}\n")
        f.write(f"伪标签: 异常={n_pos}  正常={n_neg}  未标记={n_unk}\n\n")
        f.write("各模型异常数:\n")
        for c in ["iforest_anomaly", "ocsvm_anomaly", "lof_anomaly", "xgb_pred", "lgb_pred", "rf_pred"]:
            if c in df.columns:
                f.write(f"  {c}: {df[c].sum()}\n")
        f.write(f"\n投票分布:\n{df['vote_anomaly_cnt'].value_counts().sort_index().to_string()}\n\n")
        f.write("4 级分层结果:\n")
        f.write(df["risk_level"].value_counts().to_string() + "\n")
    print(f"  模型对比报告 model_comparison.txt")

    # 模型相关性矩阵
    pred_cols = [c for c in ["iforest_anomaly", "ocsvm_anomaly", "lof_anomaly", "xgb_pred", "lgb_pred", "rf_pred"] if c in df.columns]
    if len(pred_cols) > 1:
        corr = df[pred_cols].corr()
        plt.figure(figsize=(8, 6))
        sns.heatmap(corr, annot=True, fmt=".2f", cmap="YlOrRd", xticklabels=pred_cols, yticklabels=pred_cols)
        plt.title("Model Prediction Correlation")
        plt.tight_layout()
        plt.savefig(os.path.join(OUT, "model_correlation.png"), dpi=120)
        plt.close()
        corr.to_csv(os.path.join(OUT, "model_correlation.csv"))

    # 4 级分布图
    plt.figure(figsize=(8, 5))
    df["risk_level"].value_counts().reindex(["高风险", "中风险", "疑似风险", "普通用户"]).plot.bar(color=["#d62728", "#ff7f0e", "#ffbb78", "#1f77b4"])
    plt.title("Risk Level Distribution")
    plt.ylabel("Device Count")
    plt.xticks(rotation=0)
    plt.tight_layout()
    plt.savefig(os.path.join(OUT, "risk_level_distribution.png"), dpi=120)
    plt.close()

    print(f"\n[完成] 输出在 {OUT}")
    print(f"  - device_risk_score.csv   4 级风险分层结果")
    print(f"  - model_comparison.txt    模型对比报告")
    print(f"  - shap_global_importance.csv  SHAP 全局重要性")
    print(f"  - shap_summary.png         SHAP summary 图")
    print(f"  - tree_rules.txt/png       决策树规则")
    print(f"  - model_correlation.png   模型相关性热力图")
    print(f"  - risk_level_distribution.png  4 级分布图")


if __name__ == "__main__":
    main()
