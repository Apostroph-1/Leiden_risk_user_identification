# 设备号维度指标体系

> 以**设备号**为主键做风险指标，跨账号识别同一物理设备的异常行为
> 设备号字段口径：
> - 机票：`uid`（订单表 `flight.dwd_ord_wide_order_di.uid`，票维度 `o_uid` 同源）
> - 酒店：`device_id`（订单表 `hotel.dwd_ord_order_detail_di.device_id`，`orig_device_id` 备用）
> - 门票：`trace_uid`（订单表 `ticket.dwd_ord_order_detail_di.trace_uid`，`trace_gid` 作辅助关联）
> - 工单：无设备号，通过 `order_no` 反查各业务线订单取设备号

---

## 一、设备号 vs user_id 的差异定位

| 维度 | user_id | device_id |
|---|---|---|
| 粒度 | 一个账号 | 一台设备 |
| 风险盲区 | 多账号薅羊毛（同一设备切号） | 设备更换/重装会断链 |
| 核心价值 | 账号生命周期行为 | **跨账号聚集**、**团伙识别** |
| 优先级 | 主维度 | 互补维度，特别用于反欺诈 |

**建模策略**：device_id 维度作为**补充特征**进模型，不替代 user_id 主键。

---

## 二、设备号核心指标分类

### A. 跨账号聚集（device_id 最核心价值）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_distinct_user_id_cnt_30d` | 关联 user_id | 30d 同设备不同账号数 | **多账号薅羊毛**（最关键） |
| `dt_distinct_username_cnt_30d` | 关联 qunar_username | 30d 同设备不同用户名数 | 同上 |
| `dt_distinct_mobile_cnt_30d` | 关联 contact_mob | 30d 同设备不同联系人手机数 | 通讯聚集 |
| `dt_distinct_email_cnt_30d` | 机票 contact_email | 30d 同设备不同邮箱数 | 邮箱聚集 |
| `dt_user_switch_cnt_30d` | 按时序计算 | 30d 账号切换次数 | 频繁切号 |
| `dt_user_switch_rate_30d` | 按时序计算 | 30d 切号订单占比 | 切号比例 |
| `dt_max_user_per_day_30d` | 按日聚合 | 30d 单日最多账号数 | 单日多账号极值 |

### B. 跨业务线聚集（device_id 跨业务线）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_cross_biz_cnt_30d` | 各业务线设备号 | 30d 同设备跨业务线数 | **跨业务线薅羊毛** |
| `dt_cross_biz_order_cnt_30d` | 各业务线订单数 | 30d 同设备跨业务线总订单数 | 跨线规模 |
| `dt_cross_biz_refund_rate_30d` | 各业务线退款 | 30d 同设备跨业务线退款率 | 跨线退款 |
| `dt_cross_biz_compensation_rate_30d` | comp 关联 | 30d 同设备跨业务线赔付率 | 跨线赔付 |
| `dt_cross_biz_pay_tool_cnt_30d` | 支付表 brand_id | 30d 同设备跨业务线支付工具数 | 跨线支付聚集 |
| `dt_cross_biz_distinct_ip_cnt_30d` | 各订单表 ip | 30d 同设备跨业务线不同IP数 | 跨线IP聚集 |
| `dt_flight_cnt_30d` | 机票 uid | 30d 同设备机票订单数 | 机票规模 |
| `dt_hotel_cnt_30d` | 酒店 device_id | 30d 同设备酒店订单数 | 酒店规模 |
| `dt_ticket_cnt_30d` | 门票 trace_uid | 30d 同设备门票订单数 | 门票规模 |

### C. 机票设备号指标（uid 维度）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_flight_order_cnt_7d/30d/90d` | order_no | 窗口内订单数 | 规模 |
| `dt_flight_pay_ok_amount_30d` | total_price | 30d 支付总额 | 金额规模 |
| `dt_flight_refund_rate_30d` | refund_amount | 30d 退款率 | 退款异常 |
| `dt_flight_cancel_rate_30d` | status | 30d 取消率 | 取消异常 |
| `dt_flight_compensation_rate_30d` | comp 关联 | 30d 赔付率 | 赔付异常 |
| `dt_flight_scalper_cnt_30d` | is_scalper | 30d 黄牛标记订单数 | 已识别黄牛 |
| `dt_flight_intercept_cnt_30d` | intercept_result | 30d 被拦截订单数 | 已被风控 |
| `dt_flight_distinct_passenger_cnt_30d` | p_passenger_name | 30d 不同乘机人数 | **代购识别**（设备级） |
| `dt_flight_distinct_passenger_card_cnt_30d` | p_card_num | 30d 不同乘机人证件数 | 团伙识别 |
| `dt_flight_distinct_dep_city_cnt_30d` | dep_city | 30d 不同出发城市数 | 异地异常 |
| `dt_flight_distinct_arr_city_cnt_30d` | arr_city | 30d 不同到达城市数 | 多点到达 |
| `dt_flight_distinct_flight_num_cnt_30d` | flight_num | 30d 不同航班数 | 航班聚集 |
| `dt_flight_distinct_pay_tool_cnt_30d` | pay_tool_id | 30d 不同支付工具数 | 支付工具聚集 |
| `dt_flight_distinct_ip_cnt_30d` | ip | 30d 不同IP数 | IP聚集 |
| `dt_flight_distinct_contact_mob_cnt_30d` | contact_mob | 30d 不同联系人手机数 | 手机聚集 |
| `dt_flight_night_order_cnt_30d` | create_time | 30d 0-6点下单数 | 夜间异常 |
| `dt_flight_pre_day_avg_30d` | pre_day | 30d 平均提前购票天数 | 临飞下单 |
| `dt_flight_min_refund_interval_sec_30d` | refund_apply_time - pay_time | 30d 最短支付到退款间隔 | 快速退款 |
| `dt_flight_voucher_sum_30d` | voucher_amount | 30d 代金券使用总额 | 券滥用 |
| `dt_flight_add_price_sum_30d` | add_price_amount | 30d 加价总额 | 加价异常 |

### D. 酒店设备号指标（device_id 维度）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_hotel_order_cnt_7d/30d/90d` | order_no | 窗口内订单数 | 规模 |
| `dt_hotel_pay_amount_30d` | payamount | 30d 支付总额 | 金额规模 |
| `dt_hotel_cancel_rate_30d` | order_status | 30d 取消率 | 取消异常 |
| `dt_hotel_abnormal_cancel_cnt_30d` | abnormal_condition_refund | 30d 规则外取消数 | 恶意取消 |
| `dt_hotel_refund_rate_30d` | refund_time | 30d 退款率 | 退款异常 |
| `dt_hotel_malice_cnt_30d` | is_malice | 30d 恶意单数 | 已识别恶意 |
| `dt_hotel_guarantee_cnt_30d` | is_guarantee | 30d 担保订单数 | 担保滥用 |
| `dt_hotel_laterpay_cnt_30d` | is_laterpay | 30d 后付订单数 | 后付滥用 |
| `dt_hotel_hourroom_cnt_30d` | is_hours_room | 30d 钟点房数 | 钟点房异常 |
| `dt_hotel_distinct_hotel_cnt_30d` | hotel_seq | 30d 不同酒店数 | 多酒店下单 |
| `dt_hotel_distinct_city_cnt_30d` | city_code | 30d 不同城市数 | 跨城异常 |
| `dt_hotel_distinct_contact_mob_cnt_30d` | contact_phone | 30d 不同联系人手机数 | 手机聚集 |
| `dt_hotel_distinct_guest_idcard_cnt_30d` | guest_idcard_info | 30d 不同住客证件数 | **住客聚集**（团伙） |
| `dt_hotel_user_hotel_distance_avg_30d` | user_hotel_distance | 30d 平均用户-酒店距离 | 远距离下单 |
| `dt_hotel_cancel_distance_avg_30d` | cancel_distance | 30d 平均取消距离 | 远距离取消 |
| `dt_hotel_room_night_sum_30d` | final_room_night | 30d 累计间夜数 | 间夜异常 |
| `dt_hotel_breakfast_sum_30d` | breakfast | 30d 早餐份数 | 早餐异常 |
| `dt_hotel_free_cancel_cnt_30d` | use_free_cancel | 30d 取消无忧订单数 | 取消无忧滥用 |
| `dt_hotel_actual_success_paymode_cnt_30d` | actual_success_paymode | 30d 极速支付订单数 | 极速支付异常 |

### E. 门票设备号指标（trace_uid 维度）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_ticket_order_cnt_7d/30d/90d` | order_id | 窗口内订单数 | 规模 |
| `dt_ticket_pay_amount_30d` | pay_money | 30d 支付总额 | 金额规模 |
| `dt_ticket_refund_rate_30d` | refund_money | 30d 退款率 | 退款异常 |
| `dt_ticket_full_refund_cnt_30d` | is_full_refund | 30d 全额退款数 | 全额退款滥用 |
| `dt_ticket_huangniu_cnt_30d` | filter_flag=2 | 30d 黄牛标记数 | 已识别黄牛 |
| `dt_ticket_brush_cnt_30d` | filter_flag=9 | 30d 刷票数 | 刷票识别 |
| `dt_ticket_zero_product_cnt_30d` | is_zero_product | 30d 零元票数 | 零元票薅羊毛 |
| `dt_ticket_one_yuan_cnt_30d` | filter_flag=5 | 30d 一元票数 | 一元票薅羊毛 |
| `dt_ticket_distinct_sight_cnt_30d` | sight_id | 30d 不同景区数 | 多景区下单 |
| `dt_ticket_distinct_sight_city_cnt_30d` | sight_city | 30d 不同景区城市数 | 跨城景区 |
| `dt_ticket_distinct_goods_cnt_30d` | goods_id | 30d 不同商品数 | 商品聚集 |
| `dt_ticket_distinct_supplier_cnt_30d` | supplier_id | 30d 不同供应商数 | 供应商聚集 |
| `dt_ticket_distinct_fp_cnt_30d` | fp | 30d 不同设备指纹数 | 设备指纹聚集 |
| `dt_ticket_distinct_mobile_cnt_30d` | order_contact_mobile | 30d 不同手机数 | 手机聚集 |
| `dt_ticket_distinct_distributor_cnt_30d` | order_distributor_id | 30d 不同分销商数 | 分销聚集 |
| `dt_ticket_hcount_sum_30d` | hcount | 30d 累计人次 | 人次规模 |
| `dt_ticket_marketing_cashback_sum_30d` | marketing_cashback_money | 30d 返现总额 | 返现滥用 |
| `dt_ticket_coupon_sum_30d` | coupon_money | 30d 代金券总额 | 券滥用 |
| `dt_ticket_red_packet_sum_30d` | order_red_packet_money | 30d 红包总额 | 红包滥用 |
| `dt_ticket_subsidy_sum_30d` | order_subsidy_money | subsidy_money | 30d 补贴总额 | 补贴滥用 |
| `dt_ticket_issue_speed_avg_30d` | issue_speed | 30d 平均出票速度 | 出票延迟 |
| `dt_ticket_refund_times_cnt_30d` | order_refund_times | 30d 退款操作次数 | 退款频次 |
| `dt_ticket_auto_refund_fail_cnt_30d` | order_refund_status=21 | 30d 自动退款失败数 | 退款失败异常 |
| `dt_ticket_takeoff_pay_interval_avg_30d` | order_takeoff_date - order_pay_time | 30d 平均支付-入园间隔 | 临入园下单 |
| `dt_ticket_local_not_match_cnt_30d` | local_city != sight_city | 30d 异地购票数 | 异地购票 |

### F. 设备号支付-退款指标
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_pay_distinct_brand_id_cnt_30d` | brand_id | 30d 不同支付方式数 | 支付工具聚集 |
| `dt_pay_distinct_merchantid_cnt_30d` | merchantid | 30d 不同商户号数 | 商户聚集 |
| `dt_pay_distinct_card_cnt_30d` | extdata.card_cnt | 30d 不同卡数 | 多卡异常 |
| `dt_pay_distinct_card_orgnz_cnt_30d` | extdata.card_orgnz | 30d 不同卡组织数 | 多卡组织 |
| `dt_pay_distinct_platform_cnt_30d` | extdata.platform | 30d 不同平台数 | 多平台异常 |
| `dt_pay_distinct_promotion_id_cnt_30d` | extdata.promotion_id | 30d 不同促销ID数 | 促销聚集 |
| `dt_pay_refund_cnt_30d` | opertype=退款 | 30d 退款笔数 | 退款频次 |
| `dt_pay_refund_amt_sum_30d` | amt (退款) | 30d 退款总额 | 退款金额 |
| `dt_pay_refund_pay_ratio_30d` | amt | 30d 退款额/支付额 | 退款率 |
| `dt_pay_self_refund_cnt_30d` | is_self=1 且 opertype=退款 | 30d 自有退款数 | 自有退款异常 |
| `dt_pay_same_day_refund_cnt_30d` | 退款日=支付日 | 30d 同日退款笔数 | 当日退款异常 |
| `dt_pay_short_interval_refund_cnt_30d` | 间隔 ≤ 1小时 | 30d 短间隔退款笔数 | 秒退异常 |

### G2. 设备号赔付指标（关联 compensation 表）
> 数据源：`default.ods_callcenterdb_cc_compensation`（comp 表保持原样，不修改）
> 关联方式：comp.order_no → 各业务线 DWD.order_no → 取 device_id（机票 uid / 酒店 device_id / 门票 trace_uid）
> 金额口径：仅统计 `compensation_status = 'pay_success'` 的赔付金额（与原 comp SQL 一致）

#### G2.1 赔付规模类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_compensation_order_cnt_7d/30d/90d` | comp.order_no | 窗口内设备关联的赔付订单数 | 赔付规模 |
| `dt_compensation_cnt_30d` | comp.order_no (去重) | 30d 赔付笔数（一笔订单可多次赔付） | 赔付频次 |
| `dt_compensation_amount_30d` | comp.compensation_amount (pay_success) | 30d 赔付金额总和 | 赔付金额规模 |
| `dt_refund_amount_30d` | comp.refund_amount (pay_success) | 30d 退款金额总和（comp 侧） | 退款金额 |
| `dt_consume_amount_30d` | comp.consume_amount (pay_success) | 30d 消费补偿金额 | 消费补偿 |
| `dt_other_amount_30d` | comp.other_amount (pay_success) | 30d 其他金额 | 其他赔付 |
| `dt_total_compensation_amount_30d` | comp.total_amount (pay_success) | 30d 赔付总金额 | 赔付总额 |

#### G2.2 赔付率类（需关联订单数计算分母）
| 指标 | 口径 | 风险语义 |
|---|---|---|
| `dt_compensation_order_rate_30d` | 30d 赔付订单数 / 30d 总订单数 | 赔付订单率 |
| `dt_compensation_amount_rate_30d` | 30d 赔付金额 / 30d 支付成功金额 | 赔付金额率 |
| `dt_refund_amount_rate_30d` | 30d comp 退款金额 / 30d 支付成功金额 | 退款金额率（comp 侧） |
| `dt_compensation_per_order_30d` | 30d 赔付金额 / 30d 总订单数 | 单均赔付金额 |
| `dt_compensation_per_pay_order_30d` | 30d 赔付金额 / 30d 支付成功订单数 | 单均赔付金额（支付口径） |

#### G2.3 赔付状态与审核类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_compensation_pay_success_cnt_30d` | compensation_status='pay_success' | 30d 赔付成功笔数 | 成功赔付频次 |
| `dt_compensation_pending_cnt_30d` | compensation_status 非 pay_success 且非终态 | 30d 待处理赔付笔数 | 在途赔付 |
| `dt_compensation_audit_pass_rate_30d` | audit_result | 30d 审核通过率 | 审核通过比例 |
| `dt_compensation_reject_cnt_30d` | reject_back 非空 | 30d 驳回笔数 | 驳回频次 |
| `dt_compensation_reject_rate_30d` | reject_back 非空 / 总赔付笔数 | 30d 驳回率 | 驳回比例 |
| `dt_compensation_reject_back_type_cnt_30d` | reject_back 去重 | 30d 不同驳回原因数 | 驳回原因多样性 |
| `dt_compensation_auto_pay_cnt_30d` | auto_pay=1 | 30d 自动赔付笔数 | 自动赔付频次 |
| `dt_compensation_auto_pay_rate_30d` | auto_pay=1 / 总赔付笔数 | 30d 自动赔付占比 | 自动赔付比例 |

#### G2.4 赔付时效类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_compensation_create_to_pay_interval_avg_30d` | create_time → pay_success 时间 | 30d 平均赔付发起到成功时长 | 赔付效率 |
| `dt_compensation_create_to_pay_interval_min_30d` | create_time → pay_success 时间 | 30d 最短赔付发起到成功时长 | 快速赔付异常 |
| `dt_compensation_update_cnt_avg_30d` | update_time - create_time | 30d 平均赔付处理时长 | 处理效率 |
| `dt_compensation_same_day_pay_cnt_30d` | pay_success 日期 = create 日期 | 30d 当日赔付成功笔数 | 当日赔付异常 |
| `dt_order_to_compensation_interval_avg_30d` | 订单 create_time → comp create_time | 30d 平均下单到发起赔付间隔 | 快速投诉识别 |
| `dt_order_to_compensation_interval_min_30d` | 订单 create_time → comp create_time | 30d 最短下单到发起赔付间隔 | 秒投诉异常 |

#### G2.5 赔付原因与责任类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_distinct_problem_name_cnt_30d` | problem_name 去重 | 30d 不同问题类型数 | 问题多样性 |
| `dt_distinct_problem_id_cnt_30d` | problem_id 去重 | 30d 不同问题ID数 | 问题ID多样性 |
| `dt_distinct_solution_cnt_30d` | solution 去重 | 30d 不同解决方案数 | 解决方案多样性 |
| `dt_distinct_detail_reason_cnt_30d` | detail_reason 去重 | 30d 不同详细原因数 | 原因多样性 |
| `dt_distinct_responser_cnt_30d` | responser 去重 | 30d 不同责任人数 | 责任人多样性 |
| `dt_distinct_responser_secondary_cnt_30d` | responser_secondary 去重 | 30d 不同二责任人数 | 二级责任人多样性 |
| `dt_distinct_compensation_way_cnt_30d` | compensation_way 去重 | 30d 不同赔付方式数 | 赔付方式多样性 |
| `dt_top_problem_name_30d` | problem_name 频次 | 30d 最高频问题类型 | 主要问题 |

#### G2.6 赔付金额分布类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_compensation_amount_avg_30d` | total_amount | 30d 平均单笔赔付金额 | 赔付均值 |
| `dt_compensation_amount_max_30d` | total_amount | 30d 最大单笔赔付金额 | 赔付极值 |
| `dt_compensation_amount_std_30d` | total_amount | 30d 赔付金额标准差 | 赔付波动 |
| `dt_compensation_amount_median_30d` | total_amount | 30d 赔付金额中位数 | 赔付中位 |
| `dt_high_compensation_cnt_30d` | total_amount > 阈值（如500） | 30d 大额赔付笔数 | 大额赔付异常 |
| `dt_compensation_amount_p90_30d` | total_amount | 30d 赔付金额 90 分位 | 赔付尾部 |

#### G2.7 跨业务线赔付类（device_id 维度特有）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_cross_biz_compensation_cnt_30d` | comp.order_no 关联多业务线 | 30d 跨业务线赔付订单数 | 跨线赔付 |
| `dt_cross_biz_compensation_amount_30d` | comp.total_amount | 30d 跨业务线赔付总金额 | 跨线赔付金额 |
| `dt_cross_biz_compensation_rate_30d` | 跨线赔付订单 / 跨线总订单 | 30d 跨业务线赔付率 | 跨线赔付率 |
| `dt_cross_biz_compensation_biz_cnt_30d` | comp.biz_line 去重 | 30d 跨业务线赔付涉及业务线数 | 跨线赔付广度 |
| `dt_cross_biz_problem_type_cnt_30d` | problem_name 跨业务线去重 | 30d 跨业务线问题类型数 | 跨线问题多样性 |

#### G2.8 设备-账号赔付分摊类（结合 device-user 映射）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_compensation_per_user_avg_30d` | comp 关联 device-user mapping | 30d 设备下单均赔付金额（按设备总账号数均摊） | 单账号赔付分摊 |
| `dt_compensation_user_concentration_30d` | comp 金额按 user_id 聚集度 | 30d 赔付金额在单设备各账号间的集中度（基尼系数） | 赔付账号集中 |
| `dt_compensation_distinct_user_cnt_30d` | comp 关联 device-user mapping | 30d 同设备有赔付的不同账号数 | 多账号赔付 |
| `dt_compensation_distinct_user_rate_30d` | 有赔付账号数 / 设备总账号数 | 30d 赔付账号占比 | 赔付账号比例 |

### G. 设备号工单指标
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_workorder_cnt_30d` | flow_log_id | 30d 工单数 | 客诉频次 |
| `dt_workorder_distinct_flow_no_cnt_30d` | flow_no | 30d 不同工单号数 | 工单聚集 |
| `dt_workorder_chat_cnt_30d` | content_type=CHAT | 30d 在线客诉数 | 在线客诉 |
| `dt_workorder_phone_cnt_30d` | content_type=PHONE | 30d 电话客诉数 | 电话客诉 |
| `dt_workorder_reopen_cnt_30d` | status 变更 | 30d 重开工单数 | 反复客诉 |
| `dt_workorder_problem_type_cnt_30d` | problem_names_after | 30d 不同问题类型数 | 问题多样性 |
| `dt_workorder_refund_type_cnt_30d` | problem_names 含退款 | 30d 退款类工单数 | 退款客诉 |
| `dt_workorder_compensation_type_cnt_30d` | problem_names 含赔付 | 30d 赔付类工单数 | 赔付客诉 |
| `dt_workorder_biz_line_cnt_30d` | biz_line | 30d 不同业务线工单数 | 跨线客诉 |

### H. 设备号图连通特征（进阶）
| 指标 | 口径 | 风险语义 |
|---|---|---|
| `device_link_user_cnt_30d` | 同设备关联账号数 | 团伙 |
| `device_link_ip_cnt_30d` | 同设备关联IP数 | 团伙 |
| `device_link_mobile_cnt_30d` | 同设备关联手机数 | 团伙 |
| `device_link_pay_tool_cnt_30d` | 同设备关联支付工具数 | 团伙 |
| `device_link_passenger_cnt_30d` | 同设备关联乘机人/入住人数 | 团伙 |
| `connected_component_id` | 连通分量ID | 团伙分组 |
| `connected_component_size` | 连通分量大小 | 团伙规模 |

---

## 三、设备号关联映射表

### 3.1 为什么需要映射表
设备号与 user_id 是多对多关系：
- 一个设备可被多个账号使用（多账号薅羊毛）
- 一个账号可在多个设备上登录（设备更换）

需要建立**设备-账号映射表**作为桥接：

```sql
-- 设备-账号映射表
CREATE TABLE leiden.dim_device_user_mapping (
    dt              STRING,
    device_id       STRING          COMMENT '统一设备号',
    biz_line        STRING          COMMENT '业务线',
    user_id         STRING,
    first_seen_time TIMESTAMP,
    last_seen_time  TIMESTAMP,
    order_cnt       BIGINT,
    PRIMARY KEY (dt, device_id, biz_line, user_id)
);
```

### 3.2 统一设备号字段
- 机票 `uid` → `device_id`
- 酒店 `device_id` → `device_id`
- 门票 `trace_uid` → `device_id`

> 三业务线的设备号字段名不同，但语义一致（设备唯一标识）。需确认三业务线的设备号是否同一套生成体系；如不是，则需建跨业务线设备号映射（通常通过 user_id 桥接）。

---

## 四、使用建议

1. **建模定位**：device_id 维度作为 user_id 的**补充特征**，不替代
2. **优先级**：
   - A 类（跨账号聚集）最关键，直接反映多账号薅羊毛
   - **G2 类（comp 赔付关联）是设备号维度的第二核心**，反映设备级赔付滥用，与 A 类组合可识别"多账号轮流薅赔付"
3. **comp 关联链路**：comp.order_no → 各业务线 DWD.order_no → device_id（机票 uid / 酒店 device_id / 门票 trace_uid）。comp 表本身不修改，仅做关联。
4. **跨业务线**：B 类需确认三业务线设备号是否同体系；如不是，先用单业务线 A/C/D/E 类
5. **图特征**：H 类需 spark graphx 或 neo4j 单独跑
6. **窗口**：统一 7d/30d/90d
7. **冷启动**：新设备无历史，用当日指标 + 业务规则兜底
8. **金额口径**：G2 类所有金额指标仅统计 `compensation_status = 'pay_success'`，与原 comp SQL 保持一致
