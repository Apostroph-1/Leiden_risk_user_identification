"""
Leiden 风险用户识别 - 离线数据导出 mysql
从 ClickHouse 拉 DWS 表，写入 mysql
"""
import os
import argparse
from datetime import datetime, timedelta
import pandas as pd
from sqlalchemy import create_engine
import clickhouse_connect


CH_HOST = os.getenv("CH_HOST", "localhost")
CH_PORT = int(os.getenv("CH_PORT", "8123"))
CH_USER = os.getenv("CH_USER", "default")
CH_PASSWORD = os.getenv("CH_PASSWORD", "")
CH_DATABASE = os.getenv("CH_DATABASE", "leiden")

MYSQL_URL = os.getenv("MYSQL_URL", "mysql+pymysql://root:root@localhost:3306/leiden?charset=utf8mb4")


def export_dws_biz_daily(start_dt: str, end_dt: str):
    client = clickhouse_connect.get_client(
        host=CH_HOST, port=CH_PORT, username=CH_USER,
        password=CH_PASSWORD, database=CH_DATABASE,
    )
    sql = f"""
    SELECT dt, biz_line, user_id,
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
    df["dt"] = pd.to_datetime(df["dt"]).dt.date
    engine = create_engine(MYSQL_URL)
    with engine.connect() as conn:
        conn.execute(f"DELETE FROM dws_user_biz_daily WHERE dt BETWEEN '{start_dt}' AND '{end_dt}'")
        conn.commit()
    df.to_sql("dws_user_biz_daily", engine, if_exists="append", index=False, chunksize=2000)
    print(f"[dws_user_biz_daily] {len(df)} 行")


def export_dws_cross_biz_daily(start_dt: str, end_dt: str):
    client = clickhouse_connect.get_client(
        host=CH_HOST, port=CH_PORT, username=CH_USER,
        password=CH_PASSWORD, database=CH_DATABASE,
    )
    sql = f"""
    SELECT dt, user_id,
        dt_cross_order_cnt, dt_cross_biz_cnt,
        dt_cross_pay_ok_amount, dt_cross_refund_amount,
        dt_cross_compensation_amount,
        dt_cross_distinct_pay_tool_cnt, dt_cross_distinct_ip_cnt,
        dt_cross_distinct_mobile_cnt
    FROM leiden.dws_user_cross_biz_daily
    WHERE dt BETWEEN '{start_dt}' AND '{end_dt}'
    """
    df = client.query_df(sql)
    df["dt"] = pd.to_datetime(df["dt"]).dt.date
    engine = create_engine(MYSQL_URL)
    with engine.connect() as conn:
        conn.execute(f"DELETE FROM dws_user_cross_biz_daily WHERE dt BETWEEN '{start_dt}' AND '{end_dt}'")
        conn.commit()
    df.to_sql("dws_user_cross_biz_daily", engine, if_exists="append", index=False, chunksize=2000)
    print(f"[dws_user_cross_biz_daily] {len(df)} 行")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--start", required=True)
    parser.add_argument("--end", required=True)
    args = parser.parse_args()
    export_dws_biz_daily(args.start, args.end)
    export_dws_cross_biz_daily(args.start, args.end)
