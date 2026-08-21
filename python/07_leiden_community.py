"""
Leiden 项目 - 团伙识别（Leiden 社区发现）
方案见 docs/07_unsupervised_risk_model.md 第四节

流程：
  1. 从宽表明细字段展开，构建节点-边表
  2. 构建 igraph 图
  3. 跑 Leiden 算法
  4. 输出团伙列表
"""
import os
import ast
import argparse
import json
import time
from collections import defaultdict
import numpy as np
import pandas as pd
import igraph as ig
import leidenalg

# ---------- 路径 ----------
BASE = r"d:/Qunar_work/workbuddy_data/leiden"
DATA = os.path.join(BASE, "data")
OUT = os.path.join(BASE, "data", "model_output")
os.makedirs(OUT, exist_ok=True)

INPUT_CSV = os.path.join(DATA, "flight_feature_detail_8.19-90days.csv")
RISK_CSV = os.path.join(OUT, "device_risk_score.csv")  # 上一步产出


def parse_array(s):
    """把 ["A","B"] 字符串解析为 list"""
    if pd.isna(s) or s == "" or s == "[]":
        return []
    try:
        val = ast.literal_eval(s)
        if isinstance(val, list):
            return [str(x).strip() for x in val if str(x).strip()]
        return [str(val).strip()]
    except Exception:
        # 兼容非标准 JSON
        return [x.strip().strip('"').strip("'") for x in str(s).strip("[]").split(",") if x.strip()]


def build_edges(df: pd.DataFrame, risk_devices: set) -> pd.DataFrame:
    """Vectorized edge building via explode - much faster than iterrows."""
    if len(df) == 0:
        return pd.DataFrame(columns=["src", "dst", "type", "src_is_risk"])
    risk_set = risk_devices

    def _make(col_name, prefix):
        sub = df[["device_id", col_name]].dropna(subset=[col_name])
        sub = sub[sub[col_name].astype(str).str.strip().isin(["", "[]"]) == False]
        if sub.empty:
            return pd.DataFrame(columns=["src", "dst", "type", "src_is_risk"])
        sub[col_name] = sub[col_name].apply(parse_array)
        sub = sub.explode(col_name)
        sub = sub[sub[col_name].notna() & (sub[col_name] != "")]
        out = pd.DataFrame({
            "src": sub["device_id"].values,
            "dst": (prefix + sub[col_name].astype(str)).values,
            "type": prefix.rstrip("::"),
            "src_is_risk": sub["device_id"].isin(risk_set).astype(int).values,
        })
        return out

    parts = []
    for col, pfx in [("flight_distinct_user_id", "user::"),
                     ("flight_pay_tool_detail", "pay::"),
                     ("flight_uid_card_info", "card::"),
                     ("flight_passenger_mobile_info", "mobile::")]:
        if col in df.columns:
            parts.append(_make(col, pfx))
    if not parts:
        return pd.DataFrame(columns=["src", "dst", "type", "src_is_risk"])
    return pd.concat(parts, ignore_index=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--risk-only", action="store_true", help="只对高危设备构图（推荐）")
    parser.add_argument("--min-community-size", type=int, default=3, help="最小团伙规模")
    args = parser.parse_args()

    # ---------- 1. 加载 ----------
    print(f"[1/4] 加载数据")
    df = pd.read_csv(INPUT_CSV)
    print(f"  宽表 {len(df)} 设备")

    risk_devices = set()
    if os.path.exists(RISK_CSV):
        r = pd.read_csv(RISK_CSV, encoding="utf-8-sig")
        risk_devices = set(r[r["risk_level"] == "高风险"]["device_id"].values)
        print(f"  风险设备 {len(risk_devices)} (来自 device_risk_score.csv)")
    else:
        print("  未找到 device_risk_score.csv，将用全量设备")

    # ---------- 2. 构图 ----------
    print(f"[2/4] 构建边表")
    if args.risk_only and risk_devices:
        df_sub = df[df["device_id"].isin(risk_devices)].copy()
        print(f"  只对 {len(df_sub)} 个风险设备构图")
    else:
        df_sub = df
    edges = build_edges(df_sub, risk_devices)
    print(f"  边数 {len(edges)}")
    if edges.empty:
        print("  无边，退出")
        return
    # exploded_edges.csv (供 community_server 加载邻接表)
    exploded = edges.rename(columns={"src": "device_id", "dst": "entity_node", "type": "entity_type"})
    exploded["entity_value"] = exploded["entity_node"].str.split("::").str[-1]
    exploded[["device_id", "entity_value", "entity_type", "entity_node"]].to_csv(
        os.path.join(OUT, "exploded_edges.csv"), index=False, encoding="utf-8-sig")

    # ---------- 3. 构建 igraph + Leiden ----------
    print(f"[3/4] 构建 igraph + Leiden 社区发现")
    # 收集节点
    nodes = list(set(edges["src"]).union(set(edges["dst"])))
    node2id = {n: i for i, n in enumerate(nodes)}
    n = len(nodes)
    print(f"  节点数 {n}")

    # 构建边列表（去重 + 加权）
    edges["src_id"] = edges["src"].map(node2id)
    edges["dst_id"] = edges["dst"].map(node2id)
    edge_list = edges.groupby(["src_id", "dst_id"]).size().reset_index(name="weight")
    el = list(zip(edge_list["src_id"], edge_list["dst_id"]))
    ew = list(edge_list["weight"])

    G = ig.Graph(n=n, edges=el, directed=False)
    G.es["weight"] = ew
    # 节点类型
    node_types = ["device" if not n.startswith(("user::", "pay::", "card::", "mobile::")) else
                  n.split("::")[0] for n in nodes]
    G.vs["name"] = nodes
    G.vs["type"] = node_types

    # Leiden
    partition = leidenalg.find_partition(G, leidenalg.ModularityVertexPartition,
                                          weights="weight", seed=42)
    comm = pd.DataFrame({
        "node": nodes,
        "node_type": node_types,
        "community_id": partition.membership,
    })
    n_comm = len(set(partition.membership))
    print(f"  社区数 {n_comm}")

    # ---------- 4. 团伙列表 ----------
    print(f"[4/4] 团伙列表（规模 ≥ {args.min_community_size}）")
    comm_stat = comm.groupby("community_id").agg(
        community_size=("node", "count"),
        device_cnt=("node_type", lambda x: sum(t == "device" for t in comm.loc[x.index, "node_type"])),
        user_cnt=("node_type", lambda x: sum(t == "user" for t in comm.loc[x.index, "node_type"])),
        pay_cnt=("node_type", lambda x: sum(t == "pay" for t in comm.loc[x.index, "node_type"])),
        card_cnt=("node_type", lambda x: sum(t == "card" for t in comm.loc[x.index, "node_type"])),
        mob_cnt=("node_type", lambda x: sum(t == "mobile" for t in comm.loc[x.index, "node_type"])),
    ).reset_index()
    comm_stat = comm_stat[comm_stat["community_size"] >= args.min_community_size].copy()
    # 重新编号社区ID（过滤后连续，与 gang_list 保持一致）
    comm_stat["community_id_new"] = range(len(comm_stat))
    comm_map = dict(zip(comm_stat["community_id"], comm_stat["community_id_new"]))
    comm["community_id"] = comm["community_id"].map(comm_map)
    comm = comm[comm["community_id"].notna()].copy()
    comm["community_id"] = comm["community_id"].astype(int)
    comm_stat["community_id"] = comm_stat["community_id_new"]
    comm_stat = comm_stat.drop(columns=["community_id_new"])

    # 写出节点级社区归属（renumbered）
    comm.to_csv(os.path.join(OUT, "device_community.csv"), index=False, encoding="utf-8-sig")

    # 高危设备数
    comm_device = comm[(comm["node_type"] == "device")]
    comm_device = comm_device.merge(
        pd.DataFrame({"node": list(risk_devices), "is_risk": 1}),
        on="node", how="left"
    )
    comm_device["is_risk"] = comm_device["is_risk"].fillna(0).astype(int)
    risk_per_comm = comm_device.groupby("community_id")["is_risk"].sum().reset_index(name="risk_device_cnt")
    comm_stat = comm_stat.merge(risk_per_comm, on="community_id", how="left")
    comm_stat["risk_device_cnt"] = comm_stat["risk_device_cnt"].fillna(0).astype(int)
    comm_stat["risk_device_rate"] = (comm_stat["risk_device_cnt"] / comm_stat["device_cnt"]).round(3)
    # 高危团伙标记
    # RISK_ONLY=True 时构图设备均为高风险, risk_device_rate 恒为 1.0,
    # 改用社区规模阈值标记高危团伙
    if args.risk_only:
        comm_stat["is_high_risk_gang"] = (comm_stat["community_size"] >= 10).astype(int)
    else:
        comm_stat["is_high_risk_gang"] = (
            (comm_stat["community_size"] >= 5) |
            (comm_stat["risk_device_rate"] >= 0.5)
        ).astype(int)
    comm_stat = comm_stat.sort_values(["is_high_risk_gang", "community_size"], ascending=[False, False])
    comm_stat.to_csv(os.path.join(OUT, "gang_list.csv"), index=False, encoding="utf-8-sig")

    # graph_adjacency.json (供 community_server 查询服务加载邻接表)
    adj = defaultdict(set)
    for dev, ents in edges.groupby("src")["dst"].apply(set).items():
        adj[dev].update(ents)
        for e in ents:
            adj[e].add(dev)
    adj_data = {
        "adjacency": {k: list(v) for k, v in adj.items()},
        "node_types": dict(zip(comm["node"], comm["node_type"])),
        "node_communities": {row["node"]: int(row["community_id"]) for _, row in comm.iterrows()},
    }
    adj_path = os.path.join(OUT, "graph_adjacency.json")
    with open(adj_path, "w", encoding="utf-8") as f:
        json.dump(adj_data, f, ensure_ascii=False)
    print(f"  graph_adjacency.json ({len(adj)} 节点)")

    # graph_edges.csv 也补上 utf-8-sig
    edges.to_csv(os.path.join(OUT, "graph_edges.csv"), index=False, encoding="utf-8-sig")

    print(f"  团伙总数 {len(comm_stat)}  高危团伙 {comm_stat['is_high_risk_gang'].sum()}")
    print(f"  最大团伙规模 {comm_stat['community_size'].max() if len(comm_stat) else 0}")
    print(f"\n[完成] 输出:")
    print(f"  - device_community.csv  节点级社区归属")
    print(f"  - gang_list.csv         团伙列表")
    print(f"  - graph_edges.csv      边表（可导入 neo4j/gephi）")
    print(f"  - exploded_edges.csv    展开边表（供查询服务）")
    print(f"  - graph_adjacency.json   邻接表（供查询服务）")


if __name__ == "__main__":
    main()
