#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""09 合并最终输出表

将原始宽表 + 社区归属 + 模型打标结果合并为一张完整 CSV。
输出列顺序: device_id -> community_id -> 原始字段 -> 派生+模型+投票+标签+风险分层

用法:
  python python/09_merge_output.py
"""
import os, sys, time
import pandas as pd
from tqdm import tqdm

BASE   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA   = os.path.join(BASE, "data")
OUTPUT = os.path.join(DATA, "model_output")

# [TUNABLE] 输入文件名
INPUT_CSV  = os.path.join(DATA, "flight_feature_detail_8.19-90days.csv")
COMM_CSV   = os.path.join(OUTPUT, "device_community.csv")
RISK_CSV   = os.path.join(OUTPUT, "device_risk_score.csv")
# [TUNABLE] 输出文件名
MERGED_CSV = os.path.join(OUTPUT, "final_merged_output.csv")


def main():
    print("[1/4] 加载数据")
    t0 = time.time()
    print("  加载原始宽表...")
    df_raw = pd.read_csv(INPUT_CSV, encoding="utf-8")
    print(f"    {len(df_raw)} 行, {len(df_raw.columns)} 列, 耗时 {time.time()-t0:.1f}s")
    # 去重: 同一 device_id 保留第一条（原始宽表可能因JOIN产生重复行）
    dup_cnt = df_raw["device_id"].duplicated().sum()
    if dup_cnt > 0:
        print(f"    [警告] 原始宽表存在 {dup_cnt} 个重复 device_id，保留第一条")
        df_raw = df_raw.drop_duplicates(subset=["device_id"], keep="first")
        print(f"    去重 {dup_cnt} 行 -> {len(df_raw)} 行")

    print("  加载社区归属...")
    df_comm = pd.read_csv(COMM_CSV, encoding="utf-8-sig")
    df_comm = df_comm[df_comm["node_type"] == "device"].copy()
    df_comm = df_comm[["node", "community_id"]].rename(columns={"node": "device_id"})
    print(f"    {len(df_comm)} 设备节点")

    print("  加载风险评分...")
    df_risk = pd.read_csv(RISK_CSV, encoding="utf-8-sig")
    print(f"    {len(df_risk)} 设备, {len(df_risk.columns)} 列")
    # 去重: 同一 device_id 保留第一条
    risk_dup = df_risk["device_id"].duplicated().sum()
    if risk_dup > 0:
        print(f"    [警告] 风险评分表存在 {risk_dup} 个重复 device_id，保留第一条")
        df_risk = df_risk.drop_duplicates(subset=["device_id"], keep="first")
        print(f"    去重 {risk_dup} 行 -> {len(df_risk)} 行")

    print("[2/4] 合并")
    df = df_raw.merge(df_comm, on="device_id", how="left")
    print(f"  社区匹配: {df['community_id'].notna().sum()} / {len(df)}")

    # [TUNABLE] 需要从风险评分表追加的列
    risk_new_cols = [
        "refund_rate", "comp_amount_rate", "is_multi_account", "is_machine_refund",
        "iforest_score", "iforest_anomaly",
        "ocsvm_score", "ocsvm_anomaly",
        "lof_score", "lof_anomaly",
        "xgb_prob", "xgb_pred",
        "lgb_prob", "lgb_pred",
        "rf_prob", "rf_pred",
        "vote_anomaly_cnt", "vote_total", "rule_hit_cnt",
        "pseudo_label", "risk_level",
    ]
    risk_new_cols = [c for c in risk_new_cols if c in df_risk.columns]
    risk_subset = df_risk[["device_id"] + risk_new_cols]
    df = df.merge(risk_subset, on="device_id", how="left")
    print(f"  风险匹配: {df['risk_level'].notna().sum()} / {len(df)}")

    # 填充未匹配的默认值
    df["community_id"] = df["community_id"].fillna(-1).astype(int)
    for col in ["iforest_anomaly", "ocsvm_anomaly", "lof_anomaly",
                "xgb_pred", "lgb_pred", "rf_pred", "is_multi_account", "is_machine_refund"]:
        if col in df.columns:
            df[col] = df[col].fillna(0).astype(int)
    df["pseudo_label"] = df["pseudo_label"].fillna(-1).astype(int)
    df["risk_level"] = df["risk_level"].fillna("未评估")

    print("[3/4] 调整列顺序")
    front = ["device_id", "community_id"]
    orig_cols = [c for c in df_raw.columns if c != "device_id"]
    new_cols = [c for c in risk_new_cols if c not in ["community_id"]]
    final_cols = front + orig_cols + new_cols
    final_cols = [c for c in final_cols if c in df.columns]
    df = df[final_cols]
    print(f"  最终列数: {len(df.columns)}")

    print("[4/4] 输出")
    t0 = time.time()
    df.to_csv(MERGED_CSV, index=False, encoding="utf-8-sig")
    fsize = os.path.getsize(MERGED_CSV) / 1024 / 1024
    print(f"  输出: {MERGED_CSV}")
    print(f"  大小: {fsize:.1f} MB, 耗时 {time.time()-t0:.1f}s")
    print(f"  最终表: {len(df)} 行 x {len(df.columns)} 列")

    print("\n=== 验证 ===")
    print(f"  community_id 非空: {df[df['community_id'] != -1].shape[0]} ({df[df['community_id'] != -1].shape[0]/len(df)*100:.1f}%)")
    print(f"  risk_level 分布:")
    print(df["risk_level"].value_counts().to_string())


if __name__ == "__main__":
    main()
