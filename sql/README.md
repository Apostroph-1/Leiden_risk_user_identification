# 线上 SQL 使用说明（v2）

## 文件清单
- `sql/04_online_sql_v2.sql` — 含扩展指标的线上 SQL（comp 表保持不动）

## 表清单（共 9 张产出表）

| 表名 | 说明 | 是否新增 |
|---|---|---|
| `leiden.dwd_flight_order_di` | 机票订单 DWD（含价格/行为/时间扩展字段） | 升级 |
| `leiden.dwd_hotel_order_di` | 酒店订单 DWD | 新增 |
| `leiden.dwd_ticket_order_di` | 门票订单 DWD | 新增 |
| `leiden.dwd_pay_refund_di` | 支付-退款 DWD（extdata 展开） | 新增 |
| `leiden.dwd_workorder_detail_di` | 工单明细 DWD | 新增 |
| `leiden.dws_flight_user_daily` | 机票用户-日宽表（含 30+ 指标） | 升级 |
| `leiden.dws_hotel_user_daily` | 酒店用户-日宽表 | 新增 |
| `leiden.dws_ticket_user_daily` | 门票用户-日宽表 | 新增 |
| `leiden.dws_pay_refund_user_daily` | 支付-退款用户-日宽表 | 新增 |
| `leiden.dws_workorder_user_daily` | 工单用户-日宽表 | 新增 |
| `leiden.dws_user_cross_biz_daily` | 跨业务线汇总 | 升级 |

> **comp 表不修改**：原 SQL 中的 `default.ods_callcenterdb_cc_compensation` 抽取逻辑保持原样，下游继续用现有口径。

## 扩展指标覆盖
- 机票：价格风险（A）+ 行为异常（B）+ 时间分布（C）+ 金额结构（D）+ 乘机人聚集（E）+ 航段聚集（F）
- 酒店：行为风险（G）+ 金额（H）
- 门票：行为风险（I）+ 营销（J）
- 支付退款：支付工具聚集（K）+ 退款行为（L）+ 退款时效（M）
- 工单：行为（N）+ 订单关联（O）
- 跨表：身份聚集（P）+ 时间序列（Q）+ 图连通（R，进阶）

详见 `docs/05_extended_metrics.md`。

## 跑批顺序

1. `dwd_flight_order_di`（机票 DWD）
2. `dwd_hotel_order_di`（酒店 DWD）
3. `dwd_ticket_order_di`（门票 DWD）
4. `dwd_pay_refund_di`（支付 DWD，extdata 展开）
5. `dwd_workorder_detail_di`（工单 DWD）
6. `dws_flight_user_daily`（机票宽表）
7. `dws_hotel_user_daily`（酒店宽表）
8. `dws_ticket_user_daily`（门票宽表）
9. `dws_pay_refund_user_daily`（支付宽表）
10. `dws_workorder_user_daily`（工单宽表，依赖 DWD 1-3 反查 user_id）
11. `dws_user_cross_biz_daily`（跨业务线汇总）

## 待业务方确认
- 酒店源表名（当前使用 `hotel.dwd_ord_order_detail_di`）
- 门票源表名（当前使用 `ticket.dwd_ord_order_detail_di`）
- 工单明细源表名（当前使用 `default.ods_callcenterdb_workorder_detail`）
- 酒店 `ip` 字段位置（当前在 `pay_info`，需确认是否需解析）
- 门票 `trace_uid` 是否可作为 user_id
- `pay_info` 中 `cardnumf6l4join` 在酒店/门票业务线是否同样可用
