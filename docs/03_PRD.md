# PRD - 风险用户识别模型（Leiden）

> 业务线：机票（首版） + 酒店 + 门票 + 工单日志（扩展）
> 约束：线上仅跑 SQL 落离线表，线下用离线表 + python + mysql 建模，Tableau 接 mysql 可视化

---

## 1. 背景与目标

### 1.1 背景
客服赔付数据显示部分用户存在高频退款、高频赔付、跨业务线薅羊毛等异常行为，造成平台资金损失与运营成本浪费。现有规则仅靠单业务线退款率阈值识别，覆盖率低、误报高。

### 1.2 目标
- 建立**用户级**风险识别模型，覆盖机票/酒店/门票多业务线
- 输出每日风险用户名单 + 风险分 + 命中规则，供客服/风控/运营使用
- 通过 Tableau 看板监控风险用户趋势、特征分布、召回与损失挽回

### 1.3 非目标
- 不做实时拦截（离线模型，T+1 产出）
- 不做支付风控（支付侧由支付团队负责）
- 不做自动化处置（人工确认后再动作）

---

## 2. 用户与场景

| 角色 | 用途 |
|---|---|
| 风控运营 | 每日查看高风险名单，决定是否降权/限流/封禁 |
| 客服主管 | 客诉来时查用户风险分，决定赔付策略 |
| 数据分析 | 通过 Tableau 分析风险特征分布、趋势、召回效果 |
| 业务方 | 评估各业务线风险水位，调整规则阈值 |

---

## 3. 风险定义（标签口径）

见 `docs/02_field_design.md` 第五节。核心五类：
1. 退款滥用 `is_refund_abuser`
2. 赔付滥用 `is_compensation_abuser`
3. 恶意取消 `is_cancel_abuser`
4. 身份聚集欺诈 `is_identity_fraud`
5. 跨业务线薅羊毛 `is_cross_biz_abuser`

综合风险 `is_risk_user` = 任一命中。

> 阈值初版基于业务经验，模型上线后按 PR 曲线调整。

---

## 4. 数据流与产出

```
线上 ODS → [线上 SQL 跑批] → 离线 DWD/DWS 表
                                  ↓
                        [线下 python 特征工程]
                                  ↓
                          mysql 特征表 + 标签表
                                  ↓
                        [线下 python 模型训练]
                                  ↓
                          mysql 模型输出表
                                  ↓
                          Tableau 接 mysql 可视化
```

### 4.1 线上 SQL 产出（每日 T+1）
- `leiden.dwd_flight_order_di`（+酒店/门票 DWD 待业务方确认源表）
- `leiden.dwd_callcenter_compensation_di`
- `leiden.dws_user_biz_daily`
- `leiden.dws_user_cross_biz_daily`

### 4.2 线下 python 产出（每日 T+1 或按需）
- `leiden.feature_user_risk_profile`（滚动窗口特征 + 行为异常特征）
- `leiden.label_user_risk`（回溯标签）
- `leiden.model_user_risk_score`（模型输出）

### 4.3 Tableau 看板
- 风险用户名单与风险分
- 各业务线风险率趋势
- 特征分布与命中规则
- 召回与损失挽回（人工标注后回填）

---

## 5. 模型方案

### 5.1 第一版：规则模型（baseline）
- 按标签定义直接打标，作为 baseline 与冷启动
- 优点：可解释、零训练成本、立刻可用
- 缺点：阈值硬、召回有限

### 5.2 第二版：监督学习
- 算法：LightGBM / XGBoost 二分类
- 标签：`is_risk_user`（综合）或五个子标签多任务
- 特征：`feature_user_risk_profile` 全量字段
- 评估：PR-AUC、召回率@1%误报、Top-K 命中率
- 输出：风险分 0-100 + Top 命中特征

### 5.3 第三版：图网络（进阶）
- 构图：用户 / 支付工具 / IP / 手机号 / 乘机人 节点，订单为边
- 算法：Node2Vec / GraphSAGE 或 GNN
- 用途：团伙识别、连通分量挖掘
- 可选不做，取决于第二版效果

---

## 6. 字段口径变更

见 `docs/01_field_dictionary.md`，共 **19 处修正**。关键变更：
- 金额聚合简化为 SUM
- user_id 全局统一为订单表自带
- refund 表先聚合再 join，避免笛卡尔积
- `refund_aount` → `refund_amount`
- comp 表数组字段收敛为标量

---

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `docs/01_field_dictionary.md` | 字段字典与口径修正 |
| `docs/02_field_design.md` | 多业务线字段体系设计 |
| `docs/03_PRD.md` | 本文档 |
| `docs/04_execution_plan.md` | 执行计划 |
| `sql/01_offline_tables.sql` | 离线建表与跑批 SQL |
| `sql/02_mysql_schema.sql` | mysql 库表结构 |
| `sql/03_export_to_mysql.sql` | 离线表导出 mysql 语句 |
| `python/01_feature_engineering.py` | 特征工程脚本 |
| `python/02_model_train.py` | 模型训练脚本 |
| `python/03_model_inference.py` | 模型推理脚本 |
| `python/04_export_to_mysql.py` | 结果写 mysql |
| `python/requirements.txt` | 依赖 |
| `tableau/README.md` | Tableau 看板配置说明 |

---

## 8. 验收标准

- 离线 SQL 可在 ClickHouse/Spark 上跑通，产出 DWD/DWS 表
- mysql 中有 `feature_user_risk_profile` / `label_user_risk` / `model_user_risk_score` 三张表
- python 脚本可一键训练并输出风险分
- Tableau 看板能筛选高风险用户、查看趋势
- 评估指标：PR-AUC ≥ 0.6，召回率@1%误报 ≥ 0.3（初版）

---

## 9. 风险与依赖

- 酒店/门票源表字段需业务方确认（首版可只用机票+客诉）
- user_id 跨业务线对齐需验证（如不一致需建 mapping 表）
- pay_info 从 2026-03-01 起准确，训练样本区受限
- 标签阈值需人工抽检校准

---

## 10. 后续迭代

- 实时化：接入流式计算，分钟级风险分
- 处置闭环：与风控规则引擎对接，自动降权/限流
- 团伙挖掘：图网络方案
- 多模型：分业务线子模型 + 跨业务线融合模型
