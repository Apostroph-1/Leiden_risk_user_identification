"""
Leiden 风险用户识别 - 特征工程
从 ClickHouse 读取 DWS 宽表 + 部分明细，产出 feature_user_risk_profile
写入 mysql leiden.feature_user_risk_profile
"""
import os
import argparse
from datetime import datetime, timedelta
import pandas as pd
import numpy as np
from sqlalchemy import create_engine
import clickhouse_connect


# -------------------- 配置 --------------------
CH_HOST = os.getenv("CH_HOST", "localhost")
CH_PORT = int(os.getenv("CH_PORT", "8123"))
CH_USER = os.getenv("CH_USER", "default")
CH_PASSWORD = os.getenv("CH_PASSWORD", "")
CH_DATABASE = os.getenv("CH_DATABASE", "leiden")

MYSQL_URL = os.getenv("MYSQL_URL", "mysql+pymysql://root:root@localhost:3306/leiden?charset=utf8mb4")

FEATURE_TABLE = "feature_user_risk_profile"


# -------------------- ClickHouse 取数 --------------------
def get_ch_client():
    return clickhouse_connect.get_client(
        host=CH_HOST, port=CH_PORT, username=CH_USER,
        password=CH_PASSWORD, database=CH_DATABASE,
    )


def fetch_dws_biz_daily(client, start_dt: str, end_dt: str) -> pd.DataFrame:
    """读取 dws_user_biz_daily，按 user_id 聚合到所需窗口"""
    sql = f"""
    SELECT user_id, dt, biz_line,
        dt_total_order_cnt, dt_pay_ok_order_cnt, dt_pay_ok_order_amount,
        dt_ticket_success_order_cnt, dt_cancel_order_cnt,
        dt_refund_order_cnt, dt_refund_amount, dt_gq_order_cnt,
        dt_compensation_cnt, dt_compensation_amount,
        dt_distinct_pay_tool_cnt, dt_distinct_ip_cnt,
        dt_distinct_contact_mob_cnt, dt_distinct_passenger_cnt,
        dt_max_order_amount
    FROM leiden.dws_user_biz_daily
    WHERE dt BETWEEN '{start_dt}' AND '{end_dt}'
    """
    df = client.query_df(sql)
    df["dt"] = pd.to_datetime(df["dt"])
    return df


def fetch_flight_detail(client, start_dt: str, end_dt: str) -> pd.DataFrame:
    """读取机票明细，用于行为异常特征（最短间隔、夜间下单、黄牛代购）"""
    sql = f"""
    SELECT dt, order_no, user_id, total_price, pay_time,
        flight_num, passenger_name, dep_date
    FROM leiden.dwd_flight_order_di
    WHERE dt BETWEEN '{start_dt}' AND '{end_dt}'
    """
    df = client.query_df(sql)
    df["dt"] = pd.to_datetime(df["dt"])
    df["pay_time"] = pd.to_datetime(df["pay_time"])
    return df


def fetch_comp_detail(client, start_dt: str, end_dt: str) -> pd.DataFrame:
    """读取客诉明细，用于驳回笔数/自动赔付率/问题类型多样性"""
    sql = f"""
    SELECT dt, order_no, user_id, biz_line,
        audit_result, reject_back, auto_pay, problem_name
    FROM leiden.dwd_callcenter_compensation_di
    WHERE dt BETWEEN '{start_dt}' AND '{end_dt}'
    """
    df = client.query_df(sql)
    df["dt"] = pd.to_datetime(df["dt"])
    return df


# -------------------- 特征计算 --------------------
def calc_window_features(biz_daily: pd.DataFrame, snapshot_dt: datetime, window: int) -> pd.DataFrame:
    """对单个窗口(7/30/90)做用户级聚合"""
    start = snapshot_dt - timedelta(days=window - 1)
    df = biz_daily[(biz_daily["dt"] >= start) & (biz_daily["dt"] <= snapshot_dt)].copy()
    if df.empty:
        return pd.DataFrame(columns=["user_id"])

    g = df.groupby("user_id", as_index=False).agg(
        order_cnt=("dt_total_order_cnt", "sum"),
        pay_ok_amount=("dt_pay_ok_order_amount", "sum"),
        refund_order_cnt=("dt_refund_order_cnt", "sum"),
        refund_amount=("dt_refund_amount", "sum"),
        cancel_order_cnt=("dt_cancel_order_cnt", "sum"),
        compensation_cnt=("dt_compensation_cnt", "sum"),
        compensation_amount=("dt_compensation_amount", "sum"),
        distinct_pay_tool_cnt=("dt_distinct_pay_tool_cnt", "sum"),
        distinct_ip_cnt=("dt_distinct_ip_cnt", "sum"),
        distinct_contact_mob_cnt=("dt_distinct_contact_mob_cnt", "sum"),
        distinct_passenger_cnt=("dt_distinct_passenger_cnt", "sum"),
        max_order_amount=("dt_max_order_amount", "max"),
    )
    # 风险率
    g[f"refund_rate_{window}d"] = np.where(g["order_cnt"] > 0, g["refund_order_cnt"] / g["order_cnt"], 0)
    g[f"refund_amount_rate_{window}d"] = np.where(g["pay_ok_amount"] > 0, g["refund_amount"] / g["pay_ok_amount"], 0)
    g[f"cancel_rate_{window}d"] = np.where(g["order_cnt"] > 0, g["cancel_order_cnt"] / g["order_cnt"], 0)
    g[f"compensation_rate_{window}d"] = np.where(g["order_cnt"] > 0, g["compensation_cnt"] / g["order_cnt"], 0)
    g[f"compensation_amount_rate_{window}d"] = np.where(g["pay_ok_amount"] > 0, g["compensation_amount"] / g["pay_ok_amount"], 0)
    # 重命名
    rename = {
        "order_cnt": f"order_cnt_{window}d",
        "pay_ok_amount": f"pay_ok_amount_{window}d",
        "distinct_pay_tool_cnt": f"distinct_pay_tool_cnt_{window}d",
        "distinct_ip_cnt": f"distinct_ip_cnt_{window}d",
        "distinct_contact_mob_cnt": f"distinct_contact_mob_cnt_{window}d",
        "distinct_passenger_cnt": f"distinct_passenger_cnt_{window}d",
        "max_order_amount": f"max_order_amount_{window}d",
    }
    g = g.rename(columns=rename)
    keep = ["user_id"] + [c for c in g.columns if c != "user_id"]
    return g[keep]


def calc_cross_biz_cnt(biz_daily: pd.DataFrame, snapshot_dt: datetime, window: int) -> pd.DataFrame:
    """跨业务线数：在窗口内 distinct biz_line"""
    start = snapshot_dt - timedelta(days=window - 1)
    df = biz_daily[(biz_daily["dt"] >= start) & (biz_daily["dt"] <= snapshot_dt)]
    g = df.groupby("user_id")["biz_line"].nunique().reset_index(name=f"cross_biz_cnt_{window}d")
    return g


def calc_behavior_features(flight_detail: pd.DataFrame, snapshot_dt: datetime) -> pd.DataFrame:
    """行为异常特征（仅 30d 窗口示例）"""
    start = snapshot_dt - timedelta(days=29)
    df = flight_detail[(flight_detail["dt"] >= start) & (flight_detail["dt"] <= snapshot_dt)].copy()
    if df.empty:
        return pd.DataFrame(columns=["user_id", "min_interval_between_order_min_7d",
                                     "night_order_cnt_30d", "same_flight_diff_passenger_cnt_30d",
                                     "same_passenger_diff_user_cnt_30d"])

    # 最短订单间隔（7d）
    df7 = df[df["dt"] >= snapshot_dt - timedelta(days=6)].sort_values(["user_id", "pay_time"])
    df7["prev_pay"] = df7.groupby("user_id")["pay_time"].shift(1)
    df7["interval"] = (df7["pay_time"] - df7["prev_pay"]).dt.total_seconds()
    min_interval = df7.groupby("user_id")["interval"].min().reset_index(name="min_interval_between_order_min_7d")

    # 夜间下单数
    df["hour"] = df["pay_time"].dt.hour
    night = df[df["hour"].between(0, 6)].groupby("user_id").size().reset_index(name="night_order_cnt_30d")

    # 同航班不同乘机人（黄牛）
    df["psg_set"] = df["passenger_name"].apply(lambda x: set(x) if x is not None and isinstance(x, (list, tuple, np.ndarray)) else set())
    flight_psg = df.groupby(["flight_num", "user_id"])["psg_set"].apply(lambda s: set().union(*s)).reset_index()
    flight_psg_cnt = flight_psg.groupby("user_id")["psg_set"].apply(lambda s: sum(len(x) for x in s)).reset_index(name="same_flight_diff_passenger_cnt_30d")

    # 同乘机人不同账号（代购）
    psg_user = df.explode("passenger_name")[["user_id", "passenger_name"]].dropna()
    psg_user_cnt = psg_user.groupby("passenger_name")["user_id"].nunique().reset_index(name="user_cnt_per_psg")
    same_psg_diff_user = psg_user_cnt[psg_user_cnt["user_cnt_per_psg"] > 1].set_index("passenger_name")["user_cnt_per_psg"]
    df["same_psg_diff_user_flag"] = df["passenger_name"].apply(
        lambda arr: any(same_psg_diff_user.get(p, 1) > 1 for p in (arr or [])) if arr is not None else False
    )
    spu = df.groupby("user_id")["same_psg_diff_user_flag"].sum().reset_index(name="same_passenger_diff_user_cnt_30d")

    out = min_interval.merge(night, on="user_id", how="outer") \
                     .merge(flight_psg_cnt, on="user_id", how="outer") \
                     .merge(spu, on="user_id", how="outer")
    return out


def calc_comp_features(comp_detail: pd.DataFrame, snapshot_dt: datetime) -> pd.DataFrame:
    """客诉侧特征"""
    start = snapshot_dt - timedelta(days=29)
    df = comp_detail[(comp_detail["dt"] >= start) & (comp_detail["dt"] <= snapshot_dt)].copy()
    if df.empty:
        return pd.DataFrame(columns=["user_id", "compensation_reject_cnt_30d",
                                     "compensation_auto_pay_rate_30d", "distinct_problem_type_cnt_30d"])

    df["is_reject"] = df["reject_back"].apply(lambda x: 1 if x and len(x) > 0 else 0)
    df["is_auto"] = df["auto_pay"].apply(lambda x: 1 if str(x) in ("1", "true", "True") else 0)

    g = df.groupby("user_id", as_index=False).agg(
        compensation_reject_cnt_30d=("is_reject", "sum"),
        auto_pay_cnt=("is_auto", "sum"),
        total_comp=("order_no", "count"),
    )
    g["compensation_auto_pay_rate_30d"] = np.where(g["total_comp"] > 0, g["auto_pay_cnt"] / g["total_comp"], 0)

    # 问题类型多样性
    df["problem_set"] = df["problem_name"].apply(lambda x: set(x) if x is not None else set())
    pt = df.groupby("user_id")["problem_set"].apply(lambda s: len(set().union(*s))).reset_index(name="distinct_problem_type_cnt_30d")

    g = g.merge(pt, on="user_id", how="outer")
    return g[["user_id", "compensation_reject_cnt_30d", "compensation_auto_pay_rate_30d", "distinct_problem_type_cnt_30d"]]


# -------------------- 主流程 --------------------
def build_features(snapshot_dt: datetime, write_mysql: bool = True):
    print(f"[特征工程] snapshot_dt={snapshot_dt.date()}")
    client = get_ch_client()

    # 取数范围：90d 回溯
    start_dt = (snapshot_dt - timedelta(days=89)).strftime("%Y-%m-%d")
    end_dt = snapshot_dt.strftime("%Y-%m-%d")

    biz_daily = fetch_dws_biz_daily(client, start_dt, end_dt)
    flight_detail = fetch_flight_detail(client, start_dt, end_dt)
    comp_detail = fetch_comp_detail(client, start_dt, end_dt)

    # 三窗口聚合
    feat_7 = calc_window_features(biz_daily, snapshot_dt, 7)
    feat_30 = calc_window_features(biz_daily, snapshot_dt, 30)
    feat_90 = calc_window_features(biz_daily, snapshot_dt, 90)

    # 跨业务线数
    cb7 = calc_cross_biz_cnt(biz_daily, snapshot_dt, 7)
    cb30 = calc_cross_biz_cnt(biz_daily, snapshot_dt, 30)
    cb90 = calc_cross_biz_cnt(biz_daily, snapshot_dt, 90)

    # 行为异常 + 客诉
    beh = calc_behavior_features(flight_detail, snapshot_dt)
    comp_feat = calc_comp_features(comp_detail, snapshot_dt)

    # 合并
    feat = feat_7.merge(feat_30, on="user_id", how="outer") \
                 .merge(feat_90, on="user_id", how="outer") \
                 .merge(cb7, on="user_id", how="outer") \
                 .merge(cb30, on="user_id", how="outer") \
                 .merge(cb90, on="user_id", how="outer") \
                 .merge(beh, on="user_id", how="outer") \
                 .merge(comp_feat, on="user_id", how="outer")

    feat["snapshot_dt"] = snapshot_dt.date()
    feat = feat.fillna(0)

    # 列顺序对齐 mysql 表
    cols = [
        "snapshot_dt", "user_id",
        "order_cnt_7d", "order_cnt_30d", "order_cnt_90d",
        "pay_ok_amount_7d", "pay_ok_amount_30d", "pay_ok_amount_90d",
        "cross_biz_cnt_7d", "cross_biz_cnt_30d", "cross_biz_cnt_90d",
        "refund_rate_7d", "refund_rate_30d", "refund_rate_90d",
        "refund_amount_rate_7d", "refund_amount_rate_30d", "refund_amount_rate_90d",
        "cancel_rate_7d", "cancel_rate_30d", "cancel_rate_90d",
        "compensation_rate_7d", "compensation_rate_30d", "compensation_rate_90d",
        "compensation_amount_rate_7d", "compensation_amount_rate_30d", "compensation_amount_rate_90d",
        "distinct_pay_tool_cnt_7d", "distinct_pay_tool_cnt_30d", "distinct_pay_tool_cnt_90d",
        "distinct_ip_cnt_7d", "distinct_ip_cnt_30d", "distinct_ip_cnt_90d",
        "distinct_contact_mob_cnt_7d", "distinct_contact_mob_cnt_30d", "distinct_contact_mob_cnt_90d",
        "distinct_passenger_cnt_7d", "distinct_passenger_cnt_30d", "distinct_passenger_cnt_90d",
        "min_interval_between_order_min_7d", "max_order_amount_30d", "night_order_cnt_30d",
        "same_flight_diff_passenger_cnt_30d", "same_passenger_diff_user_cnt_30d", "cross_biz_burst_cnt_7d",
        "compensation_reject_cnt_30d", "compensation_auto_pay_rate_30d", "distinct_problem_type_cnt_30d",
    ]
    for c in cols:
        if c not in feat.columns:
            feat[c] = 0
    feat = feat[cols]

    if write_mysql:
        engine = create_engine(MYSQL_URL)
        # 删除当日旧数据
        with engine.connect() as conn:
            conn.execute(f"DELETE FROM {FEATURE_TABLE} WHERE snapshot_dt = '{snapshot_dt.date()}'")
            conn.commit()
        feat.to_sql(FEATURE_TABLE, engine, if_exists="append", index=False, chunksize=2000)
        print(f"[写入 mysql] {FEATURE_TABLE} {snapshot_dt.date()} {len(feat)} 行")

    return feat


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", required=False, default=None, help="快照日 YYYY-MM-DD，默认昨天")
    args = parser.parse_args()
    snap = datetime.strptime(args.date, "%Y-%m-%d") if args.date else datetime.now() - timedelta(days=1)
    build_features(snap)
