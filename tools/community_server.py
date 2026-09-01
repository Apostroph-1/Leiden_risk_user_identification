#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""团伙社区查询服务 - Leiden 图谱路径追踪

启动: python tools/community_server.py
访问: http://127.0.0.1:8766

API:
  GET /                            前端页面
  GET /api/stats                   图统计
  GET /api/gangs?page=1&size=20    团伙列表(分页)
  GET /api/gang/<id>               团伙详情
  GET /api/gang_graph/<id>?limit=200  团伙图数据(节点+边)
 GET /api/path?a=X&b=Y            最短路径
 GET /api/paths?a=X&b=Y           多条路径
 GET /api/node/<value>            查找节点所属社区
 GET /api/community_metrics       社区指标聚合(分页)
 GET /api/community_detail/<id>   社区设备明细
"""
import os, sys, json, time, argparse, webbrowser
from collections import defaultdict, deque
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote
import pandas as pd
from tqdm import tqdm

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT  = os.path.join(BASE, "data", "model_output")
HTML_PATH = os.path.join(BASE, "tools", "community_viz.html")

# Tableau 10 palette
TABLEAU = {
    "device": "#4E79A7",
    "user":   "#F28E2B",
    "pay":    "#59A14F",
    "card":   "#E15759",
    "mobile": "#B07AA1",
}
TYPE_LABELS = {
    "device": "设备号",
    "user":   "用户ID",
    "pay":    "支付索引",
    "card":   "乘机人证件",
    "mobile": "乘机人手机",
}


class GraphEngine:
    def __init__(self, out_dir):
        self.out_dir = out_dir
        self.adj = defaultdict(set)
        self.node_type = {}
        self.node_comm = {}
        self.comm_nodes = defaultdict(list)
        self.gang_df = None
        self.merged_df = None
        # 明细行为流水（时序可视化用，懒加载）
        self.detail_df = None
        # 社区风险标签表 + 机器行为表（懒加载）
        self.risk_tags_df = None
        self.machine_df = None
        # 内网 IP 名单（data/IP地址.xlsx，绝不进 git，每次启动读取）
        self.ip_list_df = None
        self._loaded = False

    def _load_detail(self):
        """懒加载订单明细流水（26.08.27_detail.csv），供时序可视化"""
        if self.detail_df is not None:
            return self.detail_df
        # 自动发现最新 *_detail.csv（data_loader 与 notebook 同口径）
        import glob as _glob, re as _re
        _data_dir = os.path.dirname(self.out_dir)
        _cands = [os.path.basename(p) for p in _glob.glob(os.path.join(_data_dir, "*_detail.csv"))]
        _dated = [(m.group(1), f) for f in _cands if (m := _re.match(r"^(\d{2}\.\d{2}\.\d{2})_", f))]
        detail_path = os.path.join(_data_dir, sorted(_dated)[-1][1]) if _dated else os.path.join(_data_dir, "26.08.27_detail.csv")
        if not os.path.exists(detail_path):
            return None
        d = pd.read_csv(detail_path, dtype=str, encoding="utf-8",
                        usecols=["device_id", "order_no", "create_time", "pay_time",
                                 "refund_apply_time", "ip", "order_amount", "status"])
        # 明细时间格式混杂（标准 'YYYY-MM-DD HH:MM:SS' 与毫秒版并存），
        # 必须 format='mixed' 逐行解析，否则 pandas 按单一格式推断会把另一种全 coerce 成 NaT
        for c in ["create_time", "pay_time", "refund_apply_time"]:
            d[c] = pd.to_datetime(d[c], errors="coerce", format="mixed")
        d["order_amount"] = pd.to_numeric(d["order_amount"], errors="coerce")
        d["date"] = d["create_time"].dt.strftime("%Y-%m-%d")
        # 只留有下单时间的
        d = d[d["date"].notna()]
        self.detail_df = d
        return d

    def load(self):
        if self._loaded:
            return
        t0 = time.time()
        edges_path = os.path.join(self.out_dir, "exploded_edges.csv")
        comm_path  = os.path.join(self.out_dir, "device_community.csv")
        gang_path  = os.path.join(self.out_dir, "gang_list.csv")
        adj_path   = os.path.join(self.out_dir, "graph_adjacency.json")

        # 1. 加载社区归属
        print("[1/5] 加载社区归属...")
        comm_df = pd.read_csv(comm_path, encoding="utf-8-sig", dtype=str)
        # 过滤掉 NaN community_id (被筛除的小社区)
        comm_df = comm_df[comm_df["community_id"].notna()].copy()
        # 先转 float 再转 int，兼容 "6.0" 这类字符串（dtype=str 读入时常见）
        comm_df["community_id"] = comm_df["community_id"].astype(float).astype(int)
        for _, row in tqdm(comm_df.iterrows(), total=len(comm_df), desc="  社区映射"):
            self.node_type[row["node"]] = row["node_type"]
            self.node_comm[row["node"]] = int(row["community_id"])
            self.comm_nodes[int(row["community_id"])].append(row["node"])
        print(f"  节点 {len(comm_df)} 个, 社区 {len(self.comm_nodes)} 个")

        # 2. 加载团伙列表
        print("[2/5] 加载团伙列表...")
        self.gang_df = pd.read_csv(gang_path, encoding="utf-8-sig")
        print(f"  团伙 {len(self.gang_df)} 个")

        # 3. 构建邻接表
        print("[3/5] 构建邻接表...")
        if os.path.exists(adj_path):
            with open(adj_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            for node, neighbors in tqdm(data["adjacency"].items(), desc="  邻接表"):
                self.adj[node] = set(neighbors)
            # 补全 node_type 和 node_comm (JSON 中可能有些节点不在 community CSV)
            if "node_types" in data:
                for k, v in data["node_types"].items():
                    if k not in self.node_type:
                        self.node_type[k] = v
            if "node_communities" in data:
                for k, v in data["node_communities"].items():
                    if k not in self.node_comm:
                        self.node_comm[k] = v
        else:
            edges_df = pd.read_csv(edges_path, encoding="utf-8-sig")
            # 向量化构建: device -> entities
            dev_groups = edges_df.groupby("device_id")["entity_node"].apply(list)
            for dev, ents in tqdm(dev_groups.items(), total=len(dev_groups), desc="  邻接表"):
                for e in ents:
                    self.adj[dev].add(e)
                    self.adj[e].add(dev)

        print(f"  邻接表节点 {len(self.adj)} 个")
        print(f"[4/5] 加载完成, 耗时 {time.time()-t0:.1f}s")

        # 5. 加载合并输出表 (社区指标聚合用)
        merged_path = os.path.join(self.out_dir, "final_merged_output.csv")
        if os.path.exists(merged_path):
            print("[5/5] 加载合并输出表 (社区指标)...")
            t1 = time.time()
            # 只加载有社区归属的行 + 需要的列, 减少内存
            usecols = ["device_id", "community_id",
                       "flight_total_order_cnt", "flight_pay_ok_order_cnt", "flight_pay_ok_order_amount",
                       "flight_pr_total_pay", "flight_refund_amount", "flight_ticket_success_order_cnt",
                       "flight_cancel_order_cnt", "flight_refund_order_cnt", "flight_gq_order_cnt",
                       "flight_scalper_cnt", "flight_intercept_cnt", "flight_new_cnt",
                       "flight_bottom_price_order_cnt", "flight_add_price_sum",
                       "flight_voucher_sum", "flight_voucher_order_cnt",
                       "flight_night_order_cnt", "flight_weekend_order_cnt",
                       "flight_distinct_user_id_cnt", "flight_distinct_mobile_cnt",
                       "flight_uid_distinct_card_num_cnt", "flight_distinct_ip_cnt",
                       "flight_comp_total_amount", "flight_max_order_amount",
                       "flight_avg_refund_pay_interval_sec", "flight_cardinality_refund_pay_time_diff",
                       "refund_rate", "comp_amount_rate",
                       "is_short_refund_strong", "is_short_refund_weak",
            "is_machine_refund", "is_night_heavy", "is_multi_account", "is_multi_pay_tool", "is_multi_passenger",
                       "iforest_anomaly", "ocsvm_anomaly", "lof_anomaly",
                       "xgb_pred", "lgb_pred", "rf_pred",
                       "vote_anomaly_cnt", "vote_total", "rule_hit_cnt",
                       "pseudo_label", "risk_level",
                       "flight_distinct_user_id", "flight_passenger_mobile_info",
                       "flight_pay_tool_detail", "flight_distinct_pay_tool_cnt", "flight_uid_card_info"]
            # 过滤实际存在的列
            import csv as _csv
            with open(merged_path, "r", encoding="utf-8-sig") as _f:
                _reader = _csv.reader(_f)
                _header = next(_reader)
            usecols = [c for c in usecols if c in _header]
            # dtype=str prevents device_id scientific notation (8.65E+14)
            self.merged_df = pd.read_csv(merged_path, usecols=usecols, encoding="utf-8-sig", dtype=str)
            # Convert numeric columns back from string
            numeric_cols = [c for c in usecols if c not in
                ("device_id", "risk_level", "flight_distinct_user_id",
                 "flight_passenger_mobile_info", "flight_pay_tool_detail", "flight_uid_card_info")]
            for nc in numeric_cols:
                if nc in self.merged_df.columns:
                    self.merged_df[nc] = pd.to_numeric(self.merged_df[nc], errors="coerce")
            # Clean dirty string values in entity columns
            dirty = {"null", "nan", "none", "n/a", "na", "NULL", "NaN", "None", "N/A", ""}
            for sc in ("flight_distinct_user_id", "flight_passenger_mobile_info",
                       "flight_pay_tool_detail", "flight_uid_card_info"):
                if sc in self.merged_df.columns:
                    self.merged_df[sc] = self.merged_df[sc].astype(str).str.strip()
                    self.merged_df[sc] = self.merged_df[sc].replace({k: None for k in dirty})
            self.merged_df = self.merged_df[self.merged_df["community_id"] != -1].copy()
            print(f"  合并表 {len(self.merged_df)} 行 (有社区归属), {len(usecols)} 列, 耗时 {time.time()-t1:.1f}s")
        else:
            print("[5/5] final_merged_output.csv 不存在, 社区指标模块不可用")
        self._loaded = True

    def _resolve_node(self, val):
        """尝试自动匹配节点名(加前缀)"""
        val = str(val).strip()
        if val in self.adj:
            return val
        for prefix in ["user::", "pay::", "card::", "mobile::"]:
            candidate = prefix + val
            if candidate in self.adj:
                return candidate
        return None

    def find_path(self, a, b, max_depth=10):
        a_resolved = self._resolve_node(a)
        b_resolved = self._resolve_node(b)
        if a_resolved is None or b_resolved is None:
            missing = []
            if a_resolved is None: missing.append(str(a))
            if b_resolved is None: missing.append(str(b))
            return {"path": None, "message": f"节点不在图中: {missing}"}
        if a_resolved == b_resolved:
            return {"path": [a_resolved], "steps": 0, "message": "两个值相同"}

        comm_a = self.node_comm.get(a_resolved)
        comm_b = self.node_comm.get(b_resolved)
        if comm_a is not None and comm_b is not None and comm_a != comm_b:
            return {"path": None, "message": f"不在同一社区 (A={comm_a}, B={comm_b})"}

        visited = {a_resolved}
        queue = deque([(a_resolved, [a_resolved])])
        while queue:
            current, path = queue.popleft()
            if len(path) > max_depth * 2 + 1:
                continue
            for neighbor in self.adj[current]:
                if neighbor in visited:
                    continue
                new_path = path + [neighbor]
                if neighbor == b_resolved:
                    steps = []
                    for i in range(len(new_path) - 1):
                        nf, nt = new_path[i], new_path[i+1]
                        nf_type = self.node_type.get(nf, "unknown")
                        nt_type = self.node_type.get(nt, "unknown")
                        via_type = nt.split("::")[0] if "::" in nt else (nf.split("::")[0] if "::" in nf else "entity")
                        via_label = TYPE_LABELS.get(via_type, via_type)
                        steps.append({
                            "step": i + 1,
                            "from": nf,
                            "from_type": nf_type,
                            "from_label": TYPE_LABELS.get(nf_type, nf_type),
                            "to": nt,
                            "to_type": nt_type,
                            "to_label": TYPE_LABELS.get(nt_type, nt_type),
                            "via": via_label,
                        })
                    return {"path": new_path, "steps": len(new_path)-1, "detail": steps,
                            "community": comm_a, "a_raw": str(a), "b_raw": str(b)}
                visited.add(neighbor)
                queue.append((neighbor, new_path))
        return {"path": None, "message": f"超过 {max_depth} 跳未找到路径"}

    def find_all_paths(self, a, b, max_paths=5, max_depth=8):
        a_resolved = self._resolve_node(a)
        b_resolved = self._resolve_node(b)
        if a_resolved is None or b_resolved is None:
            return []
        all_paths = []
        def dfs(current, target, path, visited):
            if len(all_paths) >= max_paths:
                return
            if len(path) > max_depth * 2 + 1:
                return
            if current == target:
                all_paths.append(list(path))
                return
            for neighbor in self.adj[current]:
                if neighbor in visited:
                    continue
                visited.add(neighbor)
                path.append(neighbor)
                dfs(neighbor, target, path, visited)
                path.pop()
                visited.remove(neighbor)
        dfs(a_resolved, b_resolved, [a_resolved], {a_resolved})
        return [self._format_path(p) for p in all_paths]

    def _format_path(self, path):
        steps = []
        for i in range(len(path) - 1):
            nf, nt = path[i], path[i+1]
            steps.append({
                "from": nf, "from_type": self.node_type.get(nf, "unknown"),
                "to": nt,   "to_type": self.node_type.get(nt, "unknown"),
            })
        return {"path": path, "steps": len(path)-1, "detail": steps}

    def get_gangs(self, page=1, size=20, high_risk_only=False):
        df = self.gang_df.copy()
        if high_risk_only:
            df = df[df["is_high_risk_gang"] == 1]
        total = len(df)
        start = (page - 1) * size
        end = start + size
        page_df = df.iloc[start:end]
        return {
            "total": total, "page": page, "size": size,
            "gangs": page_df.to_dict(orient="records"),
        }

    def get_gang_detail(self, comm_id):
        nodes = self.comm_nodes.get(int(comm_id), [])
        gang_row = self.gang_df[self.gang_df["community_id"] == int(comm_id)]
        gang_info = gang_row.to_dict(orient="records")[0] if len(gang_row) > 0 else {}
        node_details = []
        for n in nodes[:500]:
            nt = self.node_type.get(n, "unknown")
            node_details.append({
                "node": n,
                "type": nt,
                "type_label": TYPE_LABELS.get(nt, ""),
                "color": TABLEAU.get(nt, "#BAB0AC"),
            })
        return {
            "community_id": int(comm_id),
            "gang_info": gang_info,
            "total_nodes": len(nodes),
            "nodes": node_details,
        }

    def get_gang_graph(self, comm_id, limit=200):
        comm_id = int(comm_id)
        nodes = self.comm_nodes.get(comm_id, [])
        if not nodes:
            return {"nodes": [], "edges": []}

        # 计算每个节点的度
        node_set = set(nodes)
        degrees = {n: len(self.adj.get(n, set()) & node_set) for n in nodes}

        # 按度排序, 取 top N
        sorted_nodes = sorted(nodes, key=lambda x: degrees[x], reverse=True)
        top_nodes = set(sorted_nodes[:limit])

        # 构建图数据
        graph_nodes = []
        for n in top_nodes:
            nt = self.node_type.get(n, "unknown")
            graph_nodes.append({
                "id": n,
                "type": nt,
                "label": TYPE_LABELS.get(nt, nt),
                "color": TABLEAU.get(nt, "#BAB0AC"),
                "degree": degrees[n],
            })

        graph_edges = []
        seen_edges = set()
        for n in top_nodes:
            for neighbor in self.adj.get(n, set()):
                if neighbor in top_nodes:
                    pair = tuple(sorted([n, neighbor]))
                    if pair not in seen_edges:
                        seen_edges.add(pair)
                        graph_edges.append({"source": n, "target": neighbor})

        return {"nodes": graph_nodes, "edges": graph_edges, "total_nodes": len(nodes), "shown_nodes": len(top_nodes)}

    def get_node_info(self, value):
        resolved = self._resolve_node(value)
        if resolved is None:
            return {"found": False, "message": f"节点 {value} 未找到"}
        nt = self.node_type.get(resolved, "unknown")
        comm = self.node_comm.get(resolved)
        neighbors = list(self.adj.get(resolved, set()))
        neighbor_details = []
        for nb in neighbors[:50]:
            nb_type = self.node_type.get(nb, "unknown")
            neighbor_details.append({
                "node": nb, "type": nb_type,
                "label": TYPE_LABELS.get(nb_type, nb_type),
                "color": TABLEAU.get(nb_type, "#BAB0AC"),
            })
        return {
            "found": True,
            "node": resolved,
            "raw_input": str(value),
            "type": nt,
            "type_label": TYPE_LABELS.get(nt, nt),
            "color": TABLEAU.get(nt, "#BAB0AC"),
            "community_id": comm,
            "degree": len(neighbors),
            "neighbors": neighbor_details,
        }

    def get_stats(self):
        return {
            "node_count": len(self.adj),
            "community_count": len(self.comm_nodes),
            "gang_count": len(self.gang_df),
            "high_risk_gang_count": int(self.gang_df["is_high_risk_gang"].sum()),
            "max_gang_size": int(self.gang_df["community_size"].max()),
        }

    def get_community_metrics(self, page=1, size=20, sort_by="comp_total", sort_dir="desc"):
        """按 community_id 聚合 final_merged_output 的统计指标"""
        if self.merged_df is None:
            return {"total": 0, "page": page, "size": size, "communities": [], "error": "final_merged_output.csv not loaded"}
        df = self.merged_df
        # 定义聚合规则: sum / mean / max
        sum_cols = [c for c in [
            "flight_total_order_cnt", "flight_pay_ok_order_cnt", "flight_pay_ok_order_amount",
            "flight_pr_total_pay", "flight_refund_amount", "flight_ticket_success_order_cnt",
            "flight_cancel_order_cnt", "flight_refund_order_cnt", "flight_gq_order_cnt",
            "flight_scalper_cnt", "flight_intercept_cnt", "flight_new_cnt",
            "flight_bottom_price_order_cnt", "flight_add_price_sum",
            "flight_voucher_sum", "flight_voucher_order_cnt",
            "flight_night_order_cnt", "flight_weekend_order_cnt",
            "flight_distinct_user_id_cnt", "flight_distinct_mobile_cnt",
            "flight_uid_distinct_card_num_cnt", "flight_distinct_ip_cnt",
            "flight_comp_total_amount", "flight_max_order_amount",
            "flight_cardinality_refund_pay_time_diff",
            "is_short_refund_strong", "is_short_refund_weak",
            "is_machine_refund", "is_night_heavy", "is_multi_account", "is_multi_pay_tool", "is_multi_passenger",
            "iforest_anomaly", "ocsvm_anomaly", "lof_anomaly",
            "xgb_pred", "lgb_pred", "rf_pred",
           "vote_anomaly_cnt", "rule_hit_cnt", "pseudo_label",
            "vote_total",
       ] if c in df.columns]
        mean_cols = [c for c in [
            "refund_rate", "comp_amount_rate", "flight_avg_refund_pay_interval_sec",
        ] if c in df.columns]
        # 分组聚合
        agg_dict = {c: "sum" for c in sum_cols}
        agg_dict.update({c: "mean" for c in mean_cols})
        agg_dict["device_id"] = "count"
        result = df.groupby("community_id").agg(agg_dict).reset_index()
        result = result.rename(columns={"device_id": "device_cnt"})
        # 风险等级分布
        if "risk_level" in df.columns:
            rl = df.groupby(["community_id", "risk_level"]).size().unstack(fill_value=0)
            for col in rl.columns:
               result[f"rl_{col}"] = rl[col].reindex(result["community_id"]).values
        # 合并团伙高危标记 (来自 gang_list.csv)
        if self.gang_df is not None and "is_high_risk_gang" in self.gang_df.columns:
            gang_info = self.gang_df[["community_id", "is_high_risk_gang"]].copy()
            # float 中转兼容 "6.0" 字符串
            gang_info["community_id"] = gang_info["community_id"].astype(float).astype(int)
            result = result.merge(gang_info, on="community_id", how="left")
            result["is_high_risk_gang"] = result["is_high_risk_gang"].fillna(0).astype(int)
       # 排序
        sort_map = {
            "comp_total": "flight_comp_total_amount",
            "refund": "flight_refund_amount",
            "order_cnt": "flight_total_order_cnt",
            "device_cnt": "device_cnt",
            "scalper": "flight_scalper_cnt",
            "intercept": "flight_intercept_cnt",
        }
        sort_col = sort_map.get(sort_by, "flight_comp_total_amount")
        if sort_col not in result.columns:
            sort_col = "device_cnt"
        ascending = (sort_dir != "desc")
        result = result.sort_values(sort_col, ascending=ascending)
        # 分页
        total = len(result)
        start = (page - 1) * size
        end = start + size
        page_df = result.iloc[start:end]
        # 转 dict, float 精度控制
        records = []
        for _, row in page_df.iterrows():
            rec = {}
            for k, v in row.items():
                if pd.isna(v):
                    rec[k] = 0
                elif isinstance(v, float):
                    rec[k] = round(float(v), 2)
                else:
                    rec[k] = int(v) if isinstance(v, (int,)) else v
            records.append(rec)
        return {"total": total, "page": page, "size": size, "communities": records}

    def get_community_detail(self, comm_id, page=1, size=50, sort_by="pay_tool"):
        """返回指定社区的设备明细，默认按支付索引个数降序"""
        if self.merged_df is None:
            return {"total": 0, "devices": [], "error": "final_merged_output.csv not loaded"}
        comm_id = int(comm_id)
        sub = self.merged_df[self.merged_df["community_id"] == comm_id].copy()
        total = len(sub)
        # 排序: 默认按支付索引个数降序，可切换
        sort_map = {"pay_tool": "flight_distinct_pay_tool_cnt", "comp": "flight_comp_total_amount",
                    "refund": "flight_refund_amount", "order": "flight_total_order_cnt"}
        sc = sort_map.get(sort_by, "flight_distinct_pay_tool_cnt")
        if sc in sub.columns:
            sub = sub.sort_values(sc, ascending=False)
        start = (page - 1) * size
        end = start + size
        page_df = sub.iloc[start:end]
        # 选择展示列 (含下钻明细字段)
        display_cols = [c for c in [
            "device_id", "community_id",
            "flight_total_order_cnt", "flight_pay_ok_order_amount",
            "flight_refund_amount", "flight_comp_total_amount",
            "flight_scalper_cnt", "flight_intercept_cnt",
            "flight_distinct_user_id_cnt", "flight_distinct_mobile_cnt",
            "flight_uid_distinct_card_num_cnt",
            "flight_distinct_pay_tool_cnt",
            "refund_rate", "comp_amount_rate",
            "is_short_refund_strong", "is_short_refund_weak",
            "is_machine_refund", "is_night_heavy", "is_multi_account", "is_multi_pay_tool", "is_multi_passenger",
            "vote_anomaly_cnt", "vote_total", "rule_hit_cnt",
            "pseudo_label", "risk_level",
            "flight_distinct_user_id", "flight_passenger_mobile_info",
            "flight_pay_tool_detail", "flight_uid_card_info",
        ] if c in page_df.columns]
        records = []
        for _, row in page_df[display_cols].iterrows():
            rec = {}
            for k, v in row.items():
                if pd.isna(v):
                    if k in ("flight_distinct_user_id", "flight_passenger_mobile_info",
                             "flight_pay_tool_detail", "flight_uid_card_info"):
                        rec[k] = ""
                    else:
                        rec[k] = 0
                elif isinstance(v, float):
                    rec[k] = round(float(v), 2)
                else:
                    rec[k] = int(v) if isinstance(v, (int,)) else v
            records.append(rec)
        return {"total": total, "page": page, "size": size,
                "community_id": comm_id, "devices": records}

    def get_device_detail(self, device_id):
        """返回指定设备的下钻明细 (userId/手机/支付索引/证件)"""
        if self.merged_df is None:
            return {"error": "final_merged_output.csv not loaded"}
        sub = self.merged_df[self.merged_df["device_id"] == device_id]
        if len(sub) == 0:
            return {"error": f"device_id {device_id} not found"}
        row = sub.iloc[0]
        def parse_list(val):
            if pd.isna(val) or not val:
                return []
            s = str(val).strip()
            if s.startswith("["):
                try:
                    return json.loads(s)
                except Exception:
                    return [x.strip().strip("'\"") for x in s.strip("[]").split(",") if x.strip()]
            return [s]
        return {
            "device_id": device_id,
            "community_id": int(row.get("community_id", -1)) if not pd.isna(row.get("community_id")) else -1,
            "risk_level": row.get("risk_level", ""),
            "flight_distinct_user_id": parse_list(row.get("flight_distinct_user_id")),
            "flight_passenger_mobile_info": parse_list(row.get("flight_passenger_mobile_info")),
            "flight_pay_tool_detail": parse_list(row.get("flight_pay_tool_detail")),
            "flight_distinct_pay_tool_cnt": int(row.get("flight_distinct_pay_tool_cnt", 0)) if not pd.isna(row.get("flight_distinct_pay_tool_cnt")) else 0,
            "flight_uid_card_info": parse_list(row.get("flight_uid_card_info")),
            "flight_distinct_user_id_cnt": int(row.get("flight_distinct_user_id_cnt", 0)) if not pd.isna(row.get("flight_distinct_user_id_cnt")) else 0,
            "flight_distinct_mobile_cnt": int(row.get("flight_distinct_mobile_cnt", 0)) if not pd.isna(row.get("flight_distinct_mobile_cnt")) else 0,
            "flight_uid_distinct_card_num_cnt": int(row.get("flight_uid_distinct_card_num_cnt", 0)) if not pd.isna(row.get("flight_uid_distinct_card_num_cnt")) else 0,
        }


    def _load_ip_list(self):
        """懒加载内网 IP 名单（data/IP地址.xlsx）。
        不写死任何 IP；文件不存在则返回 None（页签显示无名单）。
        """
        if self.ip_list_df is not None:
            return self.ip_list_df
        p = os.path.join(os.path.dirname(self.out_dir), "IP地址.xlsx")
        if not os.path.exists(p):
            return None
        try:
            ip = pd.read_excel(p, dtype=str)
        except Exception:
            # openpyxl 缺失时降级用 zipfile 解析
            try:
                import zipfile
                from xml.etree import ElementTree as ET
                z = zipfile.ZipFile(p)
                ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
                shared = []
                if "xl/sharedStrings.xml" in z.namelist():
                    root = ET.fromstring(z.read("xl/sharedStrings.xml"))
                    for si in root.findall("m:si", ns):
                        shared.append("".join(t.text or "" for t in si.iter(
                            "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t")))
                root = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
                rows = []
                for row in root.findall(".//m:row", ns):
                    cells = []
                    for c in row.findall("m:c", ns):
                        v = c.find("m:v", ns)
                        val = v.text if v is not None else ""
                        if c.get("t") == "s" and val:
                            val = shared[int(val)]
                        cells.append(val)
                    if len(cells) >= 2 and cells[1] and cells[1].lower() != "ip1":
                        rows.append({"name": cells[0], "ip": cells[1].strip()})
                ip = pd.DataFrame(rows)
            except Exception:
                return None
        else:
            ip = ip.rename(columns={ip.columns[0]: "name", ip.columns[1]: "ip"})
            ip = ip[ip["ip"].notna() & (ip["ip"].astype(str).str.lower() != "ip1")]
            ip["ip"] = ip["ip"].astype(str).str.strip()
        ip = ip.dropna(subset=["ip"]).drop_duplicates(subset=["ip"])
        # 处理通配行（如 10.90.xxx.xxx / 192.168.xxx.xxx）: 展开为 8 位前缀
        # 通配行 ip 保持 '10.90.xxx.xxx' 原样，匹配时用前缀逻辑
        self.ip_list_df = ip[["name", "ip"]]
        return self.ip_list_df

    def _ip_in_list(self, ip, exact_set, prefix_list, name_map):
        """IP 是否命中名单：先精确匹配，再通配前缀匹配（10.90.xxx.xxx -> 10.90. 前缀）"""
        if ip in exact_set:
            return name_map.get(ip)
        for pfx, name in prefix_list:
            if ip.startswith(pfx):
                return name
        return None

    def get_internal_ip_stats(self):
        """内网 IP 命中统计 + 社区聚合 + 全部命中明细"""
        ip_list = self._load_ip_list()
        if ip_list is None:
            return {"error": "IP地址.xlsx not found in data/"}
        d = self._load_detail()
        if d is None:
            return {"error": "26.08.27_detail.csv not found"}
        # 精确 IP + 通配前缀（xxx.xxx 形式）
        exact = [ip for ip in ip_list["ip"] if "x" not in ip.lower()]
        wilds = [(ip, name) for ip, name in zip(ip_list["ip"], ip_list["name"]) if "x" in ip.lower()]
        # 10.90.xxx.xxx -> 前缀 "10.90."
        prefix_list = [(".".join(ip.split(".")[:2]) + ".", name) for ip, name in wilds]
        exact_set = set(exact)
        name_map = dict(zip(ip_list["ip"], ip_list["name"]))
        # 命中明细（精确 isin + 逐行通配）
        dd = d[d["ip"].isin(exact_set)].copy()
        if prefix_list:
            rest = d[~d["ip"].isin(exact_set) & d["ip"].notna()].copy()
            def _wild_match(ip):
                for pfx, name in prefix_list:
                    if str(ip).startswith(pfx):
                        return name
                return None
            wm = rest["ip"].apply(_wild_match)
            rest = rest[wm.notna()].copy()
            rest["ip"] = rest["ip"].astype(str)
            dd = pd.concat([dd, rest], ignore_index=True)
        if dd.empty:
            return {"ip_list_cnt": len(exact_set), "matched_order_cnt": 0,
                    "matched_device_cnt": 0, "communities": [], "devices": []}
        # 社区归属
        merged = self.merged_df[["device_id", "community_id", "risk_level"]]
        dd = dd.merge(merged, on="device_id", how="left")
        dd["ip_name"] = dd["ip"].map(name_map)
        # 社区聚合
        comm_g = dd.groupby("community_id").agg(
            device_cnt=("device_id", "nunique"),
            order_cnt=("order_no", "count"),
            ip_cnt=("ip", "nunique"),
            ip_names=("ip_name", lambda s: "、".join(sorted({x for x in s if isinstance(x, str)})[:3])),
            refund_cnt=("refund_apply_time", lambda s: s.notna().sum()),
            amount=("order_amount", "sum"),
        ).reset_index().sort_values("order_cnt", ascending=False)
        communities = []
        for _, r in comm_g.iterrows():
            communities.append({
                "community_id": int(r["community_id"]) if pd.notna(r["community_id"]) else -1,
                "device_cnt": int(r["device_cnt"]), "order_cnt": int(r["order_cnt"]),
                "ip_cnt": int(r["ip_cnt"]), "ip_names": r["ip_names"],
                "refund_cnt": int(r["refund_cnt"]), "amount": round(float(r["amount"]), 2),
            })
        # 设备级明细（全部命中设备）
        dev_g = dd.groupby("device_id").agg(
            community_id=("community_id", "first"),
            risk_level=("risk_level", "first"),
            order_cnt=("order_no", "count"),
            ip_list=("ip_name", lambda s: "、".join(sorted({x for x in s if isinstance(x, str)})[:3])),
            first_time=("create_time", "min"),
            last_time=("create_time", "max"),
            refund_cnt=("refund_apply_time", lambda s: s.notna().sum()),
            amount=("order_amount", "sum"),
        ).reset_index().sort_values("order_cnt", ascending=False)
        devices = []
        for _, r in dev_g.iterrows():
            devices.append({
                "device_id": r["device_id"],
                "community_id": int(r["community_id"]) if pd.notna(r["community_id"]) else -1,
                "risk_level": r["risk_level"] if pd.notna(r["risk_level"]) else "-",
                "order_cnt": int(r["order_cnt"]),
                "ip_list": r["ip_list"],
                "first_time": str(r["first_time"])[:19],
                "last_time": str(r["last_time"])[:19],
                "refund_cnt": int(r["refund_cnt"]),
                "amount": round(float(r["amount"]), 2),
            })
        return {
            "ip_list_cnt": len(exact_set),
            "matched_order_cnt": int(len(dd)),
            "matched_device_cnt": int(dd["device_id"].nunique()),
            "matched_ip_cnt": int(dd["ip"].nunique()),
            "communities": communities,
            "devices": devices,
        }

    def _load_risk_tags(self):
        """懒加载社区风险标签表（community_risk_tags.csv）"""
        if self.risk_tags_df is not None:
            return self.risk_tags_df
        p = os.path.join(self.out_dir, "community_risk_tags.csv")
        if not os.path.exists(p):
            return None
        t = pd.read_csv(p, dtype=str, encoding="utf-8-sig")
        t["community_id"] = pd.to_numeric(t["community_id"], errors="coerce").astype("Int64")
        t = t[t["community_id"].notna()]
        t["community_id"] = t["community_id"].astype(int)
        # 标签数（排序用）
        t["tag_cnt"] = t["risk_tags"].apply(lambda s: 0 if s == "未命中" else len(str(s).split(" | ")))
        self.risk_tags_df = t
        return t

    def _load_machine(self):
        """懒加载机器行为设备表（machine_behavior_devices.csv）"""
        if self.machine_df is not None:
            return self.machine_df
        p = os.path.join(self.out_dir, "machine_behavior_devices.csv")
        if not os.path.exists(p):
            return None
        m = pd.read_csv(p, dtype=str, encoding="utf-8-sig")
        self.machine_df = m
        return m

    def get_community_timeseries(self, comm_id, max_devices=150):
        """社区时序相似性数据（SynchroTrap 风格可视化）
        返回: 社区内设备 x 日期的行为矩阵 + 每设备的 IP 集合
        结构: dates / devices:[{device_id, ip, days:{date: {cnt, refund}}}]
        """
        d = self._load_detail()
        if d is None:
            return {"error": "26.08.27_detail.csv not found"}
        # 社区设备列表
        sub = self.merged_df[self.merged_df["community_id"] == int(comm_id)]
        devs = set(sub["device_id"])
        if not devs:
            return {"error": f"community {comm_id} not found"}
        dd = d[d["device_id"].isin(devs)]
        if dd.empty:
            return {"error": "no detail data for this community"}
        # 按订单量排序取 top 设备（画图密度控制）
        # [TUNABLE] max_devices: 时序图最多展示的设备数
        top_devs = dd["device_id"].value_counts().head(max_devices).index.tolist()
        dd = dd[dd["device_id"].isin(top_devs)]
        dates = sorted(dd["date"].unique())
        # 退款标记
        dd["_is_refund"] = dd["refund_apply_time"].notna()
        g = dd.groupby(["device_id", "date"]).agg(
            cnt=("order_no", "count"), refund=("_is_refund", "max")).reset_index()
        # 设备主 IP（最常用）
        ip_main = dd.groupby("device_id")["ip"].agg(lambda s: s.mode().iloc[0] if len(s.mode()) else None)
        devices = []
        for dev in top_devs:
            row = {"device_id": dev, "ip": ip_main.get(dev), "days": {}}
            sub_g = g[g["device_id"] == dev]
            for _, r in sub_g.iterrows():
                row["days"][r["date"]] = {"c": int(r["cnt"]), "r": bool(r["refund"])}
            devices.append(row)
        return {"community_id": int(comm_id), "device_cnt": len(devs),
                "shown_devices": len(top_devs), "dates": dates, "devices": devices}

    def get_device_timeseries(self, device_id, page=1, size=50):
        """单设备时序下钻明细（点击时序图设备行后调用）"""
        d = self._load_detail()
        if d is None:
            return {"error": "26.08.27_detail.csv not found"}
        dd = d[d["device_id"] == device_id].sort_values("create_time")
        total = len(dd)
        start, end = (page - 1) * size, page * size
        pg = dd.iloc[start:end]
        orders = []
        for _, r in pg.iterrows():
            orders.append({
                "order_no": r["order_no"], "date": r["date"],
                "create_time": str(r["create_time"])[:19],
                "pay_time": str(r["pay_time"])[:19] if pd.notna(r["pay_time"]) else "",
                "refund_apply_time": str(r["refund_apply_time"])[:19] if pd.notna(r["refund_apply_time"]) else "",
                "ip": r["ip"] if pd.notna(r["ip"]) else "",
                "order_amount": round(float(r["order_amount"]), 2) if pd.notna(r["order_amount"]) else 0,
                "status": int(r["status"]) if pd.notna(r["status"]) else None,
            })
        return {"device_id": device_id, "total": total, "page": page, "size": size, "orders": orders}

    def get_community_analysis(self, page=1, size=20, sort_by="comp", sort_dir="desc", comm_id=None):
        """Aggregate communities + classify behavior patterns. comm_id 精确查询单社区"""
        if self.merged_df is None:
            return {"total": 0, "page": page, "size": size, "communities": [], "error": "final_merged_output.csv not loaded"}
        df = self.merged_df
        if comm_id is not None:
            df = df[df["community_id"] == int(comm_id)]
        sum_cols = [c for c in [
            "flight_total_order_cnt", "flight_pay_ok_order_cnt", "flight_pay_ok_order_amount",
            "flight_pr_total_pay", "flight_refund_amount", "flight_ticket_success_order_cnt",
            "flight_cancel_order_cnt", "flight_refund_order_cnt", "flight_gq_order_cnt",
            "flight_scalper_cnt", "flight_intercept_cnt", "flight_new_cnt",
            "flight_bottom_price_order_cnt", "flight_add_price_sum",
            "flight_voucher_sum", "flight_voucher_order_cnt",
            "flight_night_order_cnt", "flight_weekend_order_cnt",
            "flight_distinct_user_id_cnt", "flight_distinct_mobile_cnt",
            "flight_uid_distinct_card_num_cnt", "flight_distinct_ip_cnt",
            "flight_comp_total_amount", "flight_max_order_amount",
            "flight_cardinality_refund_pay_time_diff",
            "is_short_refund_strong", "is_short_refund_weak",
            "is_machine_refund", "is_night_heavy", "is_multi_account", "is_multi_pay_tool", "is_multi_passenger",
            "iforest_anomaly", "ocsvm_anomaly", "lof_anomaly",
            "xgb_pred", "lgb_pred", "rf_pred",
            "vote_anomaly_cnt", "rule_hit_cnt", "pseudo_label", "vote_total",
        ] if c in df.columns]
        mean_cols = [c for c in [
            "refund_rate", "comp_amount_rate", "flight_avg_refund_pay_interval_sec",
        ] if c in df.columns]
        agg_dict = {c: "sum" for c in sum_cols}
        agg_dict.update({c: "mean" for c in mean_cols})
        agg_dict["device_id"] = "count"
        result = df.groupby("community_id").agg(agg_dict).reset_index()
        result = result.rename(columns={"device_id": "device_cnt"})
        # Risk level distribution
        if "risk_level" in df.columns:
            rl = df.groupby(["community_id", "risk_level"]).size().unstack(fill_value=0)
            for col in rl.columns:
                result["rl_" + str(col)] = rl[col].reindex(result["community_id"]).values
        # Classify each community
        labels_list = []
        for _, r in result.iterrows():
            dc = max(r.get("device_cnt", 1), 1)
            uc = r.get("flight_distinct_user_id_cnt", 0)
            cc = r.get("flight_uid_distinct_card_num_cnt", 0)
            ic = r.get("flight_distinct_ip_cnt", 0)
            ma = r.get("is_multi_account", 0)
            sc = r.get("flight_scalper_cnt", 0)
            to = max(r.get("flight_total_order_cnt", 0), 1)
            cr = r.get("comp_amount_rate", 0) or 0
            rr = r.get("refund_rate", 0) or 0
            ca = r.get("flight_comp_total_amount", 0) or 0
            vs = r.get("flight_voucher_sum", 0) or 0
            pa = r.get("flight_pay_ok_order_amount", 0) or 0
            labels = []
            # 1. Black/Gray industry identity pool
            upr = uc / dc
            cpr = cc / dc
            mr = ma / dc
            if (upr > 3 or cpr > 10) and mr > 0.3:
                labels.append({"label": "黑灰产身份池", "color": "#E15759",
                    "reason": "每设备平均%.1f个userId + %.1f个证件, 多账号率%.0f%%" % (upr, cpr, mr*100)})
            # 2. Scalper
            if to > 0 and sc / to > 0.5:
                labels.append({"label": "黄牛倒票", "color": "#F28E2B",
                    "reason": "黄牛单占比%.0f%% (%d/%d)" % (sc/to*100, sc, to)})
            # 3. Compensation fraud
            if cr > 0.3 or (rr > 0.3 and cr > 0.1):
                labels.append({"label": "骗赔套利", "color": "#B07AA1",
                    "reason": "赔付率%.0f%%, 退款率%.0f%%, 赔付金额%.0f" % (cr*100, rr*100, ca)})
            # 4. Voucher abuse (preliminary)
            if pa > 0 and vs / pa > 0.05:
                labels.append({"label": "薃羊毛", "color": "#76B7B2",
                    "reason": "代金券占支付金额%.1f%%" % (vs/pa*100)})
            if not labels:
                labels.append({"label": "未归类", "color": "#BAB0AC",
                    "reason": "当前指标无法明确归类, 需补充交易级数据"})
            labels_list.append(labels)
        result["behavior_labels"] = labels_list
        # ---- 接入离线风险标签表 + 机器行为表（detail 数据派生）----
        rt = self._load_risk_tags()
        if rt is not None:
            result = result.merge(rt[["community_id", "risk_tags", "tag_cnt", "machine_devices",
                                       "machine_rate", "fast_refund_devices", "comp_rate",
                                       "refund_rate", "scalper_rate"]],
                                  on="community_id", how="left")
            result["risk_tags"] = result["risk_tags"].fillna("未命中")
            result["tag_cnt"] = result["tag_cnt"].fillna(0).astype(int)
        else:
            result["risk_tags"] = "未命中"
            result["tag_cnt"] = 0
        # Sort（新增: tags=标签数排序 / machine=机器设备数排序）
        sort_map = {"comp": "flight_comp_total_amount", "refund": "flight_refund_amount",
                     "order": "flight_total_order_cnt", "device": "device_cnt",
                     "scalper": "flight_scalper_cnt", "intercept": "flight_intercept_cnt",
                     "tags": "tag_cnt", "machine": "machine_devices"}
        sc_col = sort_map.get(sort_by, "flight_comp_total_amount")
        if sc_col not in result.columns:
            sc_col = "device_cnt"
        if sc_col == "machine_devices":
            result["machine_devices"] = result.get("machine_devices", pd.Series(dtype=float)).fillna(0)
        result = result.sort_values(sc_col, ascending=(sort_dir != "desc"))
        total = len(result)
        start = (page - 1) * size
        end = start + size
        page_df = result.iloc[start:end]
        records = []
        for _, row in page_df.iterrows():
            rec = {}
            for k, v in row.items():
                if k == "behavior_labels":
                    rec[k] = v
                elif pd.isna(v):
                    rec[k] = 0
                elif isinstance(v, float):
                    rec[k] = round(float(v), 2)
                else:
                    rec[k] = int(v) if isinstance(v, (int,)) else v
            records.append(rec)
        return {"total": total, "page": page, "size": size, "communities": records}


engine = None

class QueryHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        params = parse_qs(parsed.query)

        if path == "/" or path == "/index.html":
            self._serve_html()
        elif path == "/api/stats":
            self._send_json(engine.get_stats())
        elif path.startswith("/api/gangs"):
            page = int(params.get("page", ["1"])[0])
            size = int(params.get("size", ["20"])[0])
            hr = params.get("high_risk", ["0"])[0] == "1"
            self._send_json(engine.get_gangs(page, size, hr))
        elif path.startswith("/api/gang_graph/"):
            comm_id = path.split("/")[-1]
            limit = int(params.get("limit", ["200"])[0])
            self._send_json(engine.get_gang_graph(comm_id, limit))
        elif path.startswith("/api/gang/"):
            comm_id = path.split("/")[-1]
            self._send_json(engine.get_gang_detail(comm_id))
        elif path == "/api/path":
            a = params.get("a", [""])[0]
            b = params.get("b", [""])[0]
            max_depth = int(params.get("max_depth", ["10"])[0])
            self._send_json(engine.find_path(a, b, max_depth))
        elif path == "/api/paths":
            a = params.get("a", [""])[0]
            b = params.get("b", [""])[0]
            max_paths = int(params.get("max_paths", ["5"])[0])
            max_depth = int(params.get("max_depth", ["8"])[0])
            results = engine.find_all_paths(a, b, max_paths, max_depth)
            self._send_json({"count": len(results), "paths": results})
        elif path.startswith("/api/node/"):
            value = path.split("/", 3)[-1]
            self._send_json(engine.get_node_info(value))
        elif path == "/api/community_metrics":
            page = int(params.get("page", ["1"])[0])
            size = int(params.get("size", ["20"])[0])
            sort_by = params.get("sort", ["comp_total"])[0]
            sort_dir = params.get("dir", ["desc"])[0]
            self._send_json(engine.get_community_metrics(page, size, sort_by, sort_dir))
        elif path.startswith("/api/community_detail/"):
            parts = path.split("/")
            comm_id = parts[-1] if not parts[-1] else parts[-1]
            page = int(params.get("page", ["1"])[0])
            size = int(params.get("size", ["50"])[0])
            sort_by = params.get("sort", ["pay_tool"])[0]
            self._send_json(engine.get_community_detail(comm_id, page, size, sort_by))
        elif path.startswith("/api/device_detail/"):
            device_id = unquote(path.split("/", 3)[-1])
            self._send_json(engine.get_device_detail(device_id))
        elif path == "/api/internal_ip":
            self._send_json(engine.get_internal_ip_stats())
        elif path.startswith("/api/community_timeseries/"):
            comm_id = path.split("/")[-1]
            max_dev = int(params.get("max", ["150"])[0])
            self._send_json(engine.get_community_timeseries(comm_id, max_dev))
        elif path.startswith("/api/device_timeseries/"):
            device_id = path.split("/", 3)[-1]
            page = int(params.get("page", ["1"])[0])
            size = int(params.get("size", ["50"])[0])
            self._send_json(engine.get_device_timeseries(device_id, page, size))
        elif path == "/api/community_analysis":
            page = int(params.get("page", ["1"])[0])
            size = int(params.get("size", ["20"])[0])
            sort_by = params.get("sort", ["comp"])[0]
            sort_dir = params.get("dir", ["desc"])[0]
            comm_id = params.get("comm_id", [None])[0]
            self._send_json(engine.get_community_analysis(page, size, sort_by, sort_dir, comm_id))
        else:
            self._send_json({"error": "unknown endpoint"}, 404)

    def _serve_html(self):
        if not os.path.exists(HTML_PATH):
            self._send_json({"error": "community_viz.html not found"}, 404)
            return
        with open(HTML_PATH, "r", encoding="utf-8") as f:
            content = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(content.encode("utf-8"))

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))

    def log_message(self, fmt, *args):
        pass


def main():
    global engine
    parser = argparse.ArgumentParser(description="团伙社区查询服务")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--host", default="127.0.0.1", help="0.0.0.0 for Docker")
    parser.add_argument("--data-dir", default=OUT)
    parser.add_argument("--no-browser", action="store_true", help="skip webbrowser.open (Docker)")
    args = parser.parse_args()

    engine = GraphEngine(args.data_dir)
    engine.load()

    server = HTTPServer((args.host, args.port), QueryHandler)
    url = f"http://{args.host}:{args.port}"
    print(f"\n查询服务启动: {url}")
    print("按 Ctrl+C 终止")
    if not args.no_browser:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n服务已终止")
        server.server_close()

if __name__ == "__main__":
    main()
