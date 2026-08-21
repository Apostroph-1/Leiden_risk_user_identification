# Tableau 看板配置说明

## 数据源
- 类型：MySQL
- Host：localhost:3306
- Database：leiden
- 表：`model_user_risk_score` LEFT JOIN `feature_user_risk_profile`
  - 关联键：`snapshot_dt + user_id`

## 主数据源 SQL（自定义 SQL）

```sql
SELECT
    s.snapshot_dt,
    s.user_id,
    s.risk_score,
    s.risk_level,
    s.is_risk_user,
    s.hit_rules,
    s.top_features,
    s.model_version,
    f.order_cnt_7d, f.order_cnt_30d, f.order_cnt_90d,
    f.pay_ok_amount_30d,
    f.refund_rate_30d, f.refund_amount_rate_30d,
    f.cancel_rate_30d,
    f.compensation_rate_30d, f.compensation_amount_rate_30d,
    f.distinct_pay_tool_cnt_30d, f.distinct_ip_cnt_30d,
    f.distinct_contact_mob_cnt_30d,
    f.night_order_cnt_30d,
    f.same_flight_diff_passenger_cnt_30d,
    f.same_passenger_diff_user_cnt_30d,
    f.cross_biz_cnt_30d
FROM model_user_risk_score s
LEFT JOIN feature_user_risk_profile f
  ON s.snapshot_dt = f.snapshot_dt AND s.user_id = f.user_id
```

## 看板页面

### 页面 1：风险用户名单
- 筛选器：`snapshot_dt`、`risk_level`、`is_risk_user`、`hit_rules`
- 表格：user_id、risk_score、risk_level、hit_rules、各风险率
- 按 risk_score 降序，点击用户跳转页面 5

### 页面 2：风险趋势
- X 轴：snapshot_dt
- Y 轴：高风险用户数、风险率（高风险数 / 总用户数）
- 按 risk_level 分色
- 预警线：高风险数超过 7 日均值 1.5 倍

### 页面 3：特征分布
- 直方图：refund_rate_30d、compensation_rate_30d
- 散点图：refund_rate_30d × compensation_rate_30d，颜色为 is_risk_user
- 按 cross_biz_cnt_30d 分面

### 页面 4：召回效果
- 高风险用户数 / 人工处置数 / 损失挽回金额（需后续回填）
- 按 hit_rules 分类汇总

### 页面 5：用户画像
- 详情面板：选定 user_id 的订单数、退款率、赔付率、命中规则、Top 特征 JSON

## 权限
- 发布到 Tableau Server
- 行级权限：按业务线/团队过滤
