# Leiden 项目长期记忆

## 本地环境
- 本地 python 环境：`D:/Users/yubotai.gao/coding/python/python.exe`（已装 pandas/openpyxl/numpy）
- 系统 PATH 中的 `python` 默认指向 workbuddy 内置 python（无 pandas），需要用本地 python 时显式指定完整路径
- 用户授权：遇到需要新库时直接 `pip install` 扩展本地 python 环境后调用，无需每次询问
- 用户工作目录：`d:/Qunar_work/workbuddy_data/leiden/`（所有产出放此目录）

## 项目约束
- 线上只允许跑 SQL 产出离线表，线下用离线表 + python + mysql + tableau 建模
- comp 表（`default.ods_callcenterdb_cc_compensation`）的查询逻辑保持原样，不修改
- 字段名 xlsx 位于 `d:/Qunar_work/workbuddy_data/leiden/字段名.xlsx`，6 个 sheet：酒店/机票订单/门票/支付退款/工单/机票票维度

## 字段口径
- user_id 跨业务线统一以各业务线订单表自带的 user_id 为锚
- refund 表必须先聚合到 orderid 粒度再 join，避免笛卡尔积放大金额
- 支付退款表 extdata 包含：last_brand_id/cashier_type/new_post_flag/busi_order_no/promotion_investor/card_cnt/default_paymentway_id/user_id/platform/order_type/promotion_id/last_paycategory/card_orgnz

## 待业务方确认
- 酒店/门票/工单明细源表名
- 酒店 ip 字段位置（当前在 pay_info）
- 门票 trace_uid 是否可作为 user_id
