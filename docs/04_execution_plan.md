# 执行计划 - Leiden 风险用户识别模型

> 环境：本地 python + mysql + tableau；线上 SQL 跑批
> 人员假设：1 名数据 + 1 名业务配合

---

## 阶段总览

| 阶段 | 目标 | 关键产出 |
|---|---|---|
| P0 准备 | 口径对齐、环境就绪 | 字段确认表、mysql 库表 |
| P1 数据 | 离线表跑通、导 mysql | DWD/DWS 表、特征表 |
| P2 标签 | 回溯标注、阈值校准 | label_user_risk |
| P3 模型 | 规则版 + 监督版 | 模型输出表 |
| P4 可视化 | Tableau 看板 | 看板 |
| P5 上线 | 调度 + 复盘 | 每日产出 |

---

## P0 准备阶段

### P0.1 字段口径对齐（关键）
- [ ] 拿到酒店业务线源表 schema
- [ ] 拿到门票业务线源表 schema
- [ ] 拿到工单日志源表 schema
- [ ] 确认机票/酒店/门票 user_id 是否同账号体系
- [ ] 确认 comp.biz_line 字段值字典
- [ ] 确认 19 处口径修正业务方是否认可

### P0.2 环境准备
- [ ] 本地 mysql 建库 `leiden`
- [ ] python 环境：python 3.9+，安装 `pandas numpy scikit-learn lightgbm xgboost sqlalchemy pymysql pymysql`
- [ ] 配置 mysql 连接（写 mysql 库表 DDL）

### P0.3 线上权限申请
- [ ] 申请 ClickHouse/Spark 执行权限
- [ ] 申请 `leiden` schema 建表权限
- [ ] 申请调度任务（每日 T+1）

---

## P1 数据阶段

### P1.1 线上 DWD 表跑通
- [ ] 跑通 `sql/01_offline_tables.sql` 中的 `dwd_flight_order_di` 建表
- [ ] 跑通 `dwd_callcenter_compensation_di` 建表
- [ ] 回填 2026-03-01 至今的历史数据
- [ ] 抽样校验：随机取 10 个 order_no，比对源表与 DWD 金额、user_id、status

### P1.2 DWS 宽表跑通
- [ ] 跑通 `dws_user_biz_daily`（机票业务线）
- [ ] 跑通 `dws_user_cross_biz_daily`
- [ ] 校验：当日 user_id 数、订单数与源表一致；退款金额不被重复累加（修正 15）

### P1.3 扩展业务线（并行）
- [ ] 按酒店源表 schema 写 `dwd_hotel_order_di` ETL
- [ ] 按门票源表 schema 写 `dwd_ticket_order_di` ETL
- [ ] DWS 多业务线合并校验

### P1.4 导入 mysql
- [ ] 用 `sql/03_export_to_mysql.sql` 或 `python/04_export_to_mysql.py` 把 DWS/特征表导到 mysql
- [ ] 校验 mysql 行数与离线一致

---

## P2 标签阶段

### P2.1 回溯标注
- [ ] 用 `feature_user_risk_profile` 30d 窗口计算各风险率
- [ ] 按阈值生成 `label_user_risk` 5 个子标签 + 综合标签
- [ ] 时间切片：T-30~T-1 特征对应 T+1~T+30 标签（避免标签泄露）

### P2.2 人工抽检
- [ ] 抽 100 个 `is_risk_user=1` 的用户，人工核查是否真为风险用户
- [ ] 抽 100 个 `is_risk_user=0` 的高退款率用户，核查是否漏标
- [ ] 记录误报/漏报原因，调整阈值

### P2.3 标签分布
- [ ] 输出各子标签命中数、重叠度
- [ ] 评估正负样本比，决定是否需要重采样

---

## P3 模型阶段

### P3.1 规则版（baseline）
- [ ] 直接用标签作为输出，风险分 = 命中规则数
- [ ] 推到 mysql `model_user_risk_score`

### P3.2 监督版
- [ ] 特征工程：`python/01_feature_engineering.py` 跑全量特征
- [ ] 训练集/测试集切分：按时间切，最后 7 天做测试集
- [ ] 训练 LightGBM：5 折时序交叉验证
- [ ] 评估：PR-AUC、召回@1%FPR、Top-K 命中率
- [ ] 特征重要性排序
- [ ] 输出风险分（calibrated probability × 100）

### P3.3 模型校准
- [ ] Platt Scaling 或 Isotonic Regression 校准概率
- [ ] 风险分 buckets：0-30 低风险 / 30-70 中风险 / 70-100 高风险

### P3.4 推理与产出
- [ ] `python/03_model_inference.py` 每日跑全量用户
- [ ] 写入 mysql `model_user_risk_score`

---

## P4 可视化阶段

### P4.1 Tableau 数据源
- [ ] Tableau 接 mysql `leiden` 库
- [ ] 建立数据源：`model_user_risk_score` LEFT JOIN `feature_user_risk_profile`

### P4.2 看板页面
- [ ] 页面 1：风险用户名单（按风险分排序，可筛选业务线/标签）
- [ ] 页面 2：风险趋势（每日高风险用户数、风险率）
- [ ] 页面 3：特征分布（各特征直方图、分业务线对比）
- [ ] 页面 4：召回效果（命中规则数、人工处置率、损失挽回金额）
- [ ] 页面 5：用户画像（点击某用户查看其订单/客诉明细）

### P4.3 权限
- [ ] 看板发布到 Tableau Server
- [ ] 配置行级权限（按业务线/团队）

---

## P5 上线阶段

### P5.1 调度
- [ ] 线上：每日 T+1 02:00 跑 DWD/DWS
- [ ] 线下：每日 T+1 09:00 python 拉数据 → 训练 → 推理 → 写 mysql
- [ ] 失败重试与告警

### P5.2 监控
- [ ] 数据量监控：每日 user_id 数、订单数波动告警
- [ ] 模型监控：风险分分布漂移告警（PSI > 0.2）
- [ ] 业务监控：高风险用户数突增告警

### P5.3 复盘
- [ ] 上线 2 周后复盘：召回率、误报率、损失挽回
- [ ] 调整特征/阈值/模型
- [ ] 评估是否进入第三版图网络方案

---

## 时间排期建议

| 阶段 | 工作量 | 依赖 |
|---|---|---|
| P0 | 2-3 天 | 业务方配合确认 schema |
| P1 | 5-7 天 | P0 完成 |
| P2 | 3-5 天 | P1 完成 |
| P3 | 5-7 天 | P2 完成 |
| P4 | 3-5 天 | P3 完成 |
| P5 | 持续 | P4 完成 |

> 不给具体日期估算，按实际节奏推进。P1.3（扩展业务线）可与 P2 并行。

---

## 关键决策点

1. **是否只用机票先跑通？**
   - 建议是。机票数据全 + 客诉关联清晰，先跑通 P1-P3，再扩展酒店/门票。

2. **是否需要图网络？**
   - 取决于 P3 监督版效果。若召回够（≥0.5）且团伙问题不突出，可不做。

3. **标签阈值如何定？**
   - 初版按业务经验（02_field_design.md 第五节），P2 人工抽检后调整。

4. **模型更新频率？**
   - 风险分每日推理；模型本身周/月 retrain。

---

## 风险项

- 业务方 schema 不提供 → P0 卡住，需提前推动
- user_id 跨业务线不对齐 → 需建 mapping 表，延后多业务线合并
- 正样本太少 → 标签阈值放宽或改异常检测（Isolation Forest）
- Tableau license → 确认是否有可用 license
