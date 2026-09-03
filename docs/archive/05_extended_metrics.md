# 扩展指标清单（基于新字段表）

> 在原字段基础上新增可入模型的指标，按"用户级"输出，用于特征工程
> 标注：源表 → 字段 → 计算口径 → 风险语义
> comp 表保持不动，不在此处修改

---

## 一、机票订单表（`flight.dwd_ord_wide_order_di`）新增指标

### A. 价格风险类（薅羊毛/套利）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_avg_discount_30d` | `discount` | 30d 平均折扣率 | 长期低折扣用户可能黄牛 |
| `dt_min_discount_30d` | `discount` | 30d 最低折扣 | 探底线 |
| `dt_bottom_price_ratio_30d` | `bottom_price`, `total_price` | 30d 命中底价订单占比 | 频繁探底价可疑 |
| `dt_diffprice_high_cnt_30d` | `diffprice` | 30d 异常价差订单数 | 套利识别 |
| `dt_add_price_sum_30d` | `add_price_amount` | 30d 加价总额 | 加价订单可能是议价套利 |
| `dt_pricedepth_amount_30d` | `pricedepth_amount` | 30d 价格深度金额总和 | 深度价差越大越可疑 |
| `dt_voucher_amount_30d` | `voucher_amount` | 30d 代金券使用总额 | 滥用代金券 |
| `dt_voucher_order_rate_30d` | `voucher_amount` | 30d 用券订单占比 | 频繁用券薅羊毛 |

### B. 行为异常类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_is_scalper_cnt_30d` | `is_scalper` | 30d 被打黄牛标订单数 | 历史已识别黄牛 |
| `dt_is_gp_cnt_30d` | `is_gp` | 30d 高频单数 | 高频用户 |
| `dt_is_dxpd_cnt_30d` | `is_dxpd` | 30d 大单数 | 大额异常 |
| `dt_intercept_cnt_30d` | `intercept_result` | 30d 被拦截订单数 | 已被风控拦截过 |
| `dt_pre_day_avg_30d` | `pre_day` | 30d 平均提前购票天数 | 临飞下单异常 |
| `dt_pre_day_min_30d` | `pre_day` | 30d 最短提前天数 | 临时下单可疑 |
| `dt_is_new_cnt_30d` | `is_new`, `new_user_type` | 30d 新客订单数 | 新号风险 |
| `dt_is_fenxiao_cnt_30d` | `is_fenxiao` | 30d 分销单数 | 分销渠道异常 |
| `dt_flight_size_avg_30d` | `flight_size` | 30d 平均航段数 | 多段联程可能套利 |
| `dt_same_dep_city_cnt_30d` | `dep_city` | 30d 不同出发城市数 | 异地异常 |
| `dt_combine_order_rate_30d` | `combine_order_type` | 30d 合单订单占比 | 合单异常 |

### C. 时间分布类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_night_order_cnt_30d` | `create_time` | 30d 0-6 点下单数 | 夜间异常 |
| `dt_weekend_order_rate_30d` | `create_time` | 30d 周末订单占比 | 行为模式 |
| `dt_pay_ticket_interval_avg_30d` | `pay_time`, `ticket_time` | 30d 平均支付到出票间隔 | 出票延迟异常 |
| `dt_refund_pay_interval_avg_30d` | `refund_apply_time`, `pay_time` | 30d 平均支付到退款申请间隔 | 快速退款异常 |
| `dt_refund_complete_interval_avg_30d` | `refund_complete_time`, `refund_apply_time` | 30d 平均退款完成时长 | 退款效率 |

### D. 金额结构类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_adult_price_ratio_30d` | `adult_price`, `total_price` | 30d 成人票面占总价比例 | 票面结构异常 |
| `dt_tax_ratio_30d` | `adult_tax`, `total_price` | 30d 税费占比 | 税费套利 |
| `dt_express_price_sum_30d` | `express_price` | 30d 快递费总额 | 快递费异常 |
| `dt_service_fee_sum_30d` | `service_fee_amount` | 30d 服务费总额 | 服务费异常 |
| `dt_exp_cut_sum_30d` | `exp_cut` | 30d 补贴总额 | 补贴滥用 |

---

## 二、机票票维度表（`flight.dwd_ord_wide_order_ticket_di`）新增指标

### E. 乘机人聚集类（团伙/代购）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_distinct_passenger_name_30d` | `p_passenger_name` | 30d 不同乘机人姓名数 | 代购识别 |
| `dt_distinct_passenger_card_30d` | `p_card_num` | 30d 不同乘机人证件数 | 团伙识别 |
| `dt_distinct_passenger_mobile_30d` | `p_mobile` | 30d 不同乘机人手机数 | 通讯聚集 |
| `dt_distinct_card_city_30d` | `p_card_city` | 30d 不同证件城市数 | 跨地域异常 |
| `dt_distinct_card_province_30d` | `p_card_province` | 30d 不同证件省份数 | 跨省聚集 |
| `dt_card_expired_rate_30d` | `p_card_expired` | 30d 证件已过期订单占比 | 证件异常 |
| `dt_age_avg_30d` | `p_age` | 30d 平均乘机人年龄 | 年龄异常 |
| `dt_age_std_30d` | `p_age` | 30d 年龄标准差 | 年龄跨度大 |
| `dt_child_cnt_30d` | `is_child`, `is_include_child` | 30d 含儿童订单数 | 儿童票套利 |
| `dt_old_cnt_30d` | `is_old`, `is_include_old` | 30d 含老人订单数 | 老人票套利 |
| `dt_family_cnt_30d` | `is_family` | 30d 家庭订单数 | 家庭套餐套利 |
| `dt_distinct_eticket_30d` | `p_eticket_num` | 30d 不同票号数 | 票号聚集 |
| `dt_bx_cnt_sum_30d` | `p_bx_count` | 30d 保险总数 | 保险套利 |
| `dt_cut_price_sum_30d` | `p_cut_price` | 30d 立减总额 | 立减滥用 |
| `dt_inspect_price_diff_30d` | `p_inspect_ticket_price`, `p_price` | 30d 验票价-售价差异总和 | 验票异常 |

### F. 航段聚集类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_distinct_flight_num_30d` | `s_flight_num` | 30d 不同航班号数 | 航班聚集 |
| `dt_distinct_dep_airport_30d` | `s_dep_airport` | 30d 不同出发机场数 | 多点出发 |
| `dt_distinct_arr_airport_30d` | `s_arr_airport` | 30d 不同到达机场数 | 多点到达 |
| `dt_code_share_cnt_30d` | `s_is_code_share` | 30d 共享航班订单数 | 共享航班套利 |
| `dt_stops_cnt_30d` | `s_is_stops` | 30d 经停订单数 | 经停套利 |

---

## 三、酒店订单表新增指标

### G. 酒店行为风险类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_abnormal_cancel_cnt_30d` | `abnormal_condition_refund` | 30d 规则外取消订单数 | 恶意取消 |
| `dt_guarantee_cnt_30d` | `is_guarantee` | 30d 担保订单数 | 担保滥用 |
| `dt_guarantee_amount_sum_30d` | `guarantee_amount` | 30d 担保金额总和 | 担保金额异常 |
| `dt_buyout_cnt_30d` | `buyout_type` | 30d 买断房订单数 | 买断套利 |
| `dt_laterpay_cnt_30d` | `is_laterpay` | 30d 后付订单数 | 后付滥用 |
| `dt_hourroom_cnt_30d` | `is_hours_room` | 30d 钟点房订单数 | 钟点房异常 |
| `dt_malice_cnt_30d` | `is_malice` | 30d 恶意单数 | 已识别恶意 |
| `dt_defect_type_cnt_30d` | `defect_type` | 30d 缺陷订单数（满房/涨价） | 缺陷投诉 |
| `dt_distinct_hotel_30d` | `hotel_seq` | 30d 不同酒店数 | 多酒店下单 |
| `dt_distinct_city_30d` | `city_code` | 30d 不同城市数 | 跨城异常 |
| `dt_cancel_distance_avg_30d` | `cancel_distance` | 30d 平均取消距离 | 远距离取消 |
| `dt_user_hotel_distance_avg_30d` | `user_hotel_distance` | 30d 平均用户-酒店距离 | 远距离下单 |
| `dt_pre_sale_cnt_30d` | `is_pre_sale` | 30d 预售订单数 | 预售套利 |
| `dt_room_night_sum_30d` | `room_night`, `final_room_night` | 30d 累计间夜数 | 间夜异常 |
| `dt_breakfast_sum_30d` | `breakfast` | 30d 早餐份数总和 | 早餐异常 |
| `dt_distribute_cnt_30d` | `is_distribute` | 30d 分销订单数 | 分销异常 |
| `dt_free_cancel_cnt_30d` | `free_cancel_flag`, `use_free_cancel` | 30d 取消无忧订单数 | 取消无忧滥用 |
| `dt_singlemember_cnt_30d` | `is_singlemember` | 30d 单通订单数 | 单通异常 |
| `dt_invalid_rate_30d` | `is_valid` | 30d 无效订单占比 | 无效订单异常 |

### H. 酒店金额类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_payamount_sum_30d` | `payamount` | 30d 支付总额 | 金额规模 |
| `dt_refund_time_interval_avg_30d` | `refund_time`, `pay_time` | 30d 平均支付到退款间隔 | 快速退款 |
| `dt_actual_success_paymode_cnt_30d` | `actual_success_paymode` | 30d 极速支付订单数 | 极速支付异常 |
| `dt_is_scan_cnt_30d` | `is_scan` | 30d 扫码住订单数 | 扫码异常 |

---

## 四、门票订单表新增指标

### I. 门票行为风险类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_filter_flag_huangniu_cnt_30d` | `filter_flag` | 30d 黄牛标记订单数 (filter_flag=2) | 已识别黄牛 |
| `dt_filter_flag_test_cnt_30d` | `filter_flag` | 30d 测试订单数 (filter_flag=1) | 测试异常 |
| `dt_filter_flag_brush_cnt_30d` | `filter_flag` | 30d 刷票订单数 (filter_flag=9) | 刷票识别 |
| `dt_zero_product_cnt_30d` | `is_zero_product` | 30d 零元票订单数 | 零元票薅羊毛 |
| `dt_one_yuan_cnt_30d` | `filter_flag` | 30d 一元票订单数 (filter_flag=5) | 一元票薅羊毛 |
| `dt_full_refund_cnt_30d` | `is_full_refund` | 30d 全额退款订单数 | 全额退款滥用 |
| `dt_marketing_cashback_sum_30d` | `marketing_cashback_money` | 30d 返现总额 | 返现滥用 |
| `dt_marketing_lijian_sum_30d` | `marketing_lijian_money` | 30d 立减总额 | 立减滥用 |
| `dt_coupon_money_sum_30d` | `coupon_money` | 30d 代金券总额 | 券滥用 |
| `dt_red_packet_sum_30d` | `order_red_packet_money` | 30d 红包总额 | 红包滥用 |
| `dt_subsidy_sum_30d` | `order_subsidy_money`, `subsidy_money` | 30d 补贴总额 | 补贴滥用 |
| `dt_increase_income_sum_30d` | `increase_income` | 30d 涨价总额 | 涨价异常 |
| `dt_force_price_sum_30d` | `force_qunar_price_income`, `order_force_qunar_price_income` | 30d 强制涨价总额 | 强制涨价 |
| `dt_distinct_sight_30d` | `sight_id` | 30d 不同景区数 | 多景区下单 |
| `dt_distinct_sight_city_30d` | `sight_city` | 30d 不同景区城市数 | 跨城景区 |
| `dt_distinct_goods_30d` | `goods_id` | 30d 不同商品数 | 商品聚集 |
| `dt_distinct_supplier_30d` | `supplier_id` | 30d 不同供应商数 | 供应商聚集 |
| `dt_hcount_sum_30d` | `hcount` | 30d 累计人次 | 人次规模 |
| `dt_refund_times_cnt_30d` | `order_refund_times` | 30d 退款操作次数 | 退款频次 |
| `dt_auto_refund_fail_cnt_30d` | `order_refund_status` | 30d 自动退款失败数 (status=21) | 退款失败异常 |
| `dt_supplier_reject_cnt_30d` | `order_refund_status` | 30d 供应商拒退数 (status=24) | 拒退异常 |
| `dt_qunar_reject_cnt_30d` | `order_refund_status` | 30d Qunar拒退数 (status=26) | 拒退异常 |
| `dt_issue_speed_avg_30d` | `issue_speed` | 30d 平均出票速度 | 出票延迟 |
| `dt_takeoff_pay_interval_avg_30d` | `order_takeoff_date`, `order_pay_time` | 30d 平均支付-入园间隔 | 临入园下单 |
| `dt_refund_pay_interval_avg_30d` | `order_refund_times`, `order_pay_time` | 30d 平均支付-退款间隔 | 快速退款 |
| `dt_local_not_match_cnt_30d` | `local_city`, `sight_city` | 30d 常住地≠景区城市订单数 | 异地购票 |
| `dt_dabao_cnt_30d` | `if_dabao` | 30d 大包订单数 | 大包异常 |
| `dt_distinct_distributor_30d` | `order_distributor_id` | 30d 不同分销商数 | 分销聚集 |

### J. 门票营销类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_marketing_ticket_cnt_30d` | `order_is_marketing_ticket` | 30d 营销票订单数 | 营销票滥用 |
| `dt_self_operate_cnt_30d` | `order_self_operate` | 30d 自营订单数 | 自营比例 |
| `dt_straight_operate_cnt_30d` | `order_straight_operate` | 30d 直销订单数 | 直销比例 |
| `dt_b2b_cnt_30d` | `order_sale_type` | 30d B2B 订单数 | B2B 异常 |

---

## 五、支付-退款表（`pp_pub.dwd__qunar_selfpayord_di`）新增指标

> 含 extdata 展开字段

### K. 支付工具聚集类（核心风险特征）
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_distinct_brand_id_30d` | `brand_id` | 30d 不同支付方式数 | 支付工具聚集 |
| `dt_distinct_brand_name_30d` | `brand_name` | 30d 不同支付方式名称数 | 同上 |
| `dt_distinct_merchantid_30d` | `merchantid` | 30d 不同商户号数 | 商户聚集 |
| `dt_distinct_merchantname_30d` | `merchantname` | 30d 不同商户名称数 | 同上 |
| `dt_distinct_paymenttype_30d` | `paymenttype` | 30d 不同支付大类数 | 支付大类聚集 |
| `dt_distinct_card_cnt_30d` | `extdata.card_cnt` | 30d 不同卡数 | 多卡异常 |
| `dt_distinct_card_orgnz_30d` | `extdata.card_orgnz` | 30d 不同卡组织数 | 多卡组织 |
| `dt_distinct_last_brand_id_30d` | `extdata.last_brand_id` | 30d 不同上次支付方式数 | 支付方式切换频繁 |
| `dt_distinct_last_paycategory_30d` | `extdata.last_paycategory` | 30d 不同上次支付分类数 | 分类切换 |
| `dt_distinct_default_paymentway_30d` | `extdata.default_paymentway_id` | 30d 不同默认支付方式数 | 默认切换 |
| `dt_card_cnt_avg_30d` | `extdata.card_cnt` | 30d 平均卡数 | 多卡均值 |
| `dt_card_cnt_max_30d` | `extdata.card_cnt` | 30d 最大卡数 | 多卡极值 |

### L. 退款行为类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_refund_cnt_30d` | `opertype` | 30d 退款操作数 | 退款频次 |
| `dt_refund_amt_sum_30d` | `amt` (opertype=退款) | 30d 退款总额 | 退款金额 |
| `dt_pay_cnt_30d` | `opertype` | 30d 支付操作数 | 支付频次 |
| `dt_pay_amt_sum_30d` | `amt` (opertype=扣款) | 30d 支付总额 | 支付金额 |
| `dt_refund_pay_ratio_30d` | `amt`, `opertype` | 30d 退款额/支付额 | 退款率（金额） |
| `dt_refund_cnt_ratio_30d` | `opertype` | 30d 退款笔数/支付笔数 | 退款率（笔数） |
| `dt_self_refund_cnt_30d` | `is_self`, `opertype` | 30d 自有退款笔数 | 自有退款异常 |
| `dt_distinct_order_type_change_30d` | `order_type_change` | 30d 不同业务线数 | 跨业务线退款 |
| `dt_distinct_post_flag_30d` | `post_flag`, `extdata.new_post_flag` | 30d 不同预付后付数 | 预付后付切换 |
| `dt_distinct_platform_30d` | `extdata.platform` | 30d 不同平台数 | 多平台异常 |
| `dt_distinct_promotion_id_30d` | `extdata.promotion_id` | 30d 不同促销ID数 | 促销聚集 |
| `dt_promotion_investor_cnt_30d` | `extdata.promotion_investor` | 30d 不同促销投放方数 | 投放聚集 |
| `dt_cashier_type_cnt_30d` | `extdata.cashier_type` | 30d 不同收银台类型数 | 收银台聚集 |
| `dt_new_post_flag_cnt_30d` | `extdata.new_post_flag` | 30d 不同预付后付新标记数 | 新标记异常 |

### M. 退款时效类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_refund_interval_avg_30d` | `d` (退款日), `order_type_change` 关联支付日 | 30d 平均支付-退款间隔 | 快速退款 |
| `dt_same_day_refund_cnt_30d` | `d` 与支付日同日 | 30d 同日退款笔数 | 当日退款异常 |
| `dt_short_interval_refund_cnt_30d` | 间隔 ≤ 1小时 | 30d 短间隔退款笔数 | 秒退异常 |

---

## 六、工单明细表新增指标

### N. 工单行为类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_workorder_cnt_30d` | `flow_no` | 30d 工单数 | 客诉频次 |
| `dt_distinct_flow_no_30d` | `flow_no` | 30d 不同工单号数 | 工单聚集 |
| `dt_chat_cnt_30d` | `content_type` | 30d CHAT 工单数 | 在线客诉 |
| `dt_phone_cnt_30d` | `content_type` | 30d PHONE 工单数 | 电话客诉 |
| `dt_auto_channel_cnt_30d` | `channel_way` | 30d 自动弹屏工单数 | 自动客诉 |
| `dt_manual_channel_cnt_30d` | `channel_way` | 30d 手动弹屏工单数 | 手动客诉 |
| `dt_node_change_cnt_30d` | `node_id_after` | 30d 节点变更次数 | 流转次数 |
| `dt_manager_change_cnt_30d` | `manager_id_after` | 30d 责任人变更次数 | 责任人流转 |
| `dt_lock_change_cnt_30d` | `lock_id_after` | 30d 锁定人变更次数 | 锁定流转 |
| `dt_reopen_cnt_30d` | `status_before`, `status_after` | 30d 重开工单数 | 反复客诉 |
| `dt_problem_type_cnt_30d` | `problem_names_after` | 30d 不同问题类型数 | 问题多样性 |
| `dt_close_solution_type_cnt_30d` | `close_solution_type_id` | 30d 不同关单方案数 | 关单方案聚集 |
| `dt_close_type_cnt_30d` | `close_type` | 30d 不同关单类型数 | 关单类型聚集 |
| `dt_del_cnt_30d` | `del` | 30d 删除工单数 | 删除异常 |
| `dt_ce_need_reply_cnt_30d` | `ce_need_reply` | 30d 需回复转出工单数 | 外部转出 |
| `dt_create_cnt_30d` | `create_id` | 30d 不同创建人数 | 客服侧聚集 |
| `dt_workplace_cnt_30d` | `workplace_id` | 30d 不同职场数 | 职场聚集 |
| `dt_group_cnt_30d` | `group_id` | 30d 不同组别数 | 组别聚集 |
| `dt_log_type_cnt_30d` | `log_type` | 30d 不同日志类型数 | 日志类型聚集 |
| `dt_short_content_len_avg_30d` | `short_content` | 30d 平均简要日志长度 | 客诉复杂度 |
| `dt_content_expansion_cnt_30d` | `content_expansion` | 30d 扩展内容工单数 | 扩展信息工单 |

### O. 工单-订单关联类
| 指标 | 源字段 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_workorder_per_order_30d` | `order_no`, 工单数/订单数 | 30d 单均工单数 | 单均客诉率高 |
| `dt_no_order_workorder_cnt_30d` | `order_no` 为空 | 30d 无订单工单数 | 无单客诉 |
| `dt_distinct_order_30d` | `order_no` | 30d 不同关联订单数 | 多订单客诉 |
| `dt_biz_line_cnt_30d` | `biz_line` | 30d 不同业务线工单数 | 跨业务线客诉 |
| `dt_workorder_refund_rate_30d` | `problem_names_after` 含退款 | 30d 退款类工单占比 | 退款客诉比例 |
| `dt_workorder_compensation_rate_30d` | `problem_names_after` 含赔付 | 30d 赔付类工单占比 | 赔付客诉比例 |

---

## 七、跨表/跨业务线扩展指标

### P. 跨业务线身份聚集
| 指标 | 来源 | 口径 | 风险语义 |
|---|---|---|---|
| `dt_cross_biz_distinct_pay_tool_30d` | 支付表 brand_id | 30d 跨业务线不同支付方式数 | 跨线支付聚集 |
| `dt_cross_biz_distinct_merchant_30d` | 支付表 merchantid | 30d 跨业务线不同商户数 | 跨线商户聚集 |
| `dt_cross_biz_distinct_ip_30d` | 各订单表 ip/order_ip | 30d 跨业务线不同IP数 | 跨线IP聚集 |
| `dt_cross_biz_distinct_mobile_30d` | 各订单表 contact_mob | 30d 跨业务线不同联系人手机数 | 跨线手机聚集 |
| `dt_cross_biz_distinct_passenger_30d` | 票维度 p_passenger_name + 酒店 guest_idcard_info + 门票 hcount | 30d 跨业务线不同行人/入住人/游客数 | 跨线身份聚集 |
| `dt_cross_biz_order_cnt_30d` | 各业务线订单 | 30d 跨业务线总订单数 | 跨线规模 |
| `dt_cross_biz_refund_rate_30d` | 支付表 | 30d 跨业务线退款率 | 跨线退款 |
| `dt_cross_biz_workorder_cnt_30d` | 工单表 | 30d 跨业务线工单数 | 跨线客诉 |

### Q. 时间序列异常（需 python 算）
| 指标 | 口径 | 风险语义 |
|---|---|---|
| `order_cnt_zscore_7d_vs_30d` | (7d 均值 - 30d 均值) / 30d 标准差 | 突增 |
| `refund_rate_zscore_7d_vs_30d` | 同上 | 退款率突增 |
| `compensation_rate_zscore_7d_vs_30d` | 同上 | 赔付率突增 |
| `pay_tool_cnt_psi_7d_vs_30d` | PSI 指标 | 分布漂移 |
| `order_cnt_slope_7d` | 7 日订单数线性回归斜率 | 趋势 |
| `is_burst_user_7d` | 7 日订单数 > 历史 30d 均值 + 3σ | 突发用户 |

### R. 图连通特征（进阶）
| 指标 | 口径 | 风险语义 |
|---|---|---|
| `pay_tool_link_user_cnt_30d` | 同支付工具关联账号数 | 团伙 |
| `ip_link_user_cnt_30d` | 同IP关联账号数 | 团伙 |
| `mobile_link_user_cnt_30d` | 同手机关联账号数 | 团伙 |
| `merchant_link_user_cnt_30d` | 同商户关联账号数 | 团伙 |
| `card_link_user_cnt_30d` | 同卡号关联账号数 | 团伙 |
| `connected_component_id` | 连通分量ID | 团伙分组 |
| `connected_component_size` | 连通分量大小 | 团伙规模 |

---

## 八、使用建议

1. **优先级**：先入 A/B/C/E/G/I/K/L/N 类（与已识别风险强相关），其余作为补充
2. **去冗余**：高度相关的指标（如 `distinct_brand_id` vs `distinct_brand_name`）只取一个
3. **分桶**：连续指标建议分桶后入模型，避免量纲问题
4. **时间窗口**：统一 7d/30d/90d 三个窗口
5. **图特征**：P/R 类需要单独 spark job 跑，依赖 neo4j 或 graphx
