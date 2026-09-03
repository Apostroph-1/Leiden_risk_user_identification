# PRD - 离线风险用户识别模型（Leiden）

> 业务线：机票（当前版本）+ 酒店 + 门票 + 度假（规划扩展）
> 约束：离线 SQL 宽表导出 + 多模型打标 + Leiden 社群识别 + 前端可视化

---

## 1. 项目目标

### 1.1 背景
海外赔付数据持续显示，部分用户在机票退款、酒店赔付等业务存在异常行为，造成平台直接损失、营销成本浪费。各业务线需对异常用户进行风险评级。

### 1.2 目标
- 构建设备维度风险用户识别模型，覆盖机票/酒店/门票业务线
- 输出风险分层 + 社群关联，供风控/客服/运营使用
- 通过前端可视化工具查询社区关联和路径追溯

### 1.3 约束
- 非实时：离线 T-1 模型，非实时打分
- 非支付侧：支付索引不做风控，仅做关联
- 非自动化部署：人工确认后再推送

---

## 2. 用户与场景

| 角色 | 用途 |
|---|---|
| 风控运营 | 每日查看高风险设备，判断是否限权/封禁 |
| 客服团队 | 实时查用户风险分层、赔付金额 |
| 数据分析 | 通过前端查询社群关联和路径追溯 |
| 业务线 | 看本业务线风险水位和异常趋势 |

---

## 3. 模型架构

### 3.1 整体流程

```
原始 ODS → [离线 SQL 宽表] → 按 device_id 聚合
                                  ↓
                        [多模型分层 notebook 02]
                                  ↓
                          device_risk_score.csv
                                  ↓
                    [Leiden 社群识别 notebook 01]
                                  ↓
                  exploded_edges + device_community
                                  ↓
                    [合并输出 notebook 03]
                                  ↓
                    final_merged_output.csv
                                  ↓
                    [前端查询服务 community_server.py]
                                  ↓
                    http://127.0.0.1:8766
```

### 3.2 6 模型投票

| 类型 | 模型 | 作用 |
|---|---|---|
| 无监督 | Isolation Forest | 全局异常检测 |
| 无监督 | One-Class SVM (RBF) | 边界检测 |
| 无监督 | LOF (novelty) | 局部密度异常 |
| 监督 | XGBoost | 高精度，SHAP 可解释 |
| 监督 | LightGBM | 快速，性能不低于 XGB |
| 监督 | RandomForest | 基线参考 |

> 监督模型基于伪标签训练：强规则标注（异常=1）+ 纯正常样本（正常=0），未覆盖样本不参与训练。

### 3.3 7 条规则引擎（v2）

| 规则 | 字段 | 阈值 | 说明 |
|---|---|---|---|
| is_short_refund_strong | flight_min_refund_pay_interval_sec | <= 600s | 极可疑：10分钟内退款 |
| is_short_refund_weak | flight_min_refund_pay_interval_sec | 600s < x <= 3600s | 弱信号：1小时内退款 |
| is_machine_refund | refund_cnt - cardinality > 0 AND refund_rate > 0.5 | 退款时间间隔重复值多 + 退款率>50% |
| is_night_heavy | night_order / total | >= 0.5 | 凌晨下单占比超50%（P95） |
| is_multi_account | distinct_user_id_cnt | >= 2 | 多账号共用 |
| is_multi_pay_tool | distinct_pay_tool_cnt | >= 3 | 多支付索引 |
| is_multi_passenger | uid_distinct_card_num_cnt | >= 5 | 多乘机人证件 |

`rule_hit_cnt` = 命中规则数（0-7）

### 3.4 4 级风险分层

| 等级 | 条件 | 设备数 | 占比 |
|---|---|---|---|
| 高风险 | vote >= 60% AND rule_hit >= 2 | 25,696 | 3.0% |
| 中风险 | vote >= 2 AND rule_hit >= 1 | 201,383 | 23.3% |
| 疑似风险 | vote >= 1 OR rule_hit >= 1 | 522,080 | 60.3% |
| 普通用户 | 其余 | 116,230 | 13.4% |

### 3.5 可解释性

- SHAP TreeExplainer：XGBoost 全局/局部重要性
- 决策树 surrogate：对投票率拟合可读规则树（准确率 ~98.5%）
- 模型相关性热力图：6 模型一致性检验

---

## 4. 前端功能

| 页签 | 功能 |
|---|---|
| 高危分析 | 高危社区行为分类（黄牛/骗赔/薅羊毛等），支持搜索+下钻 |
| 社区指标 | community_id 聚合统计，支持搜索+下钻 |
| 社群图谱 | D3.js 力导向图，全屏/拖拽/缩放/搜索 |
| 路径查询 | 任意两值 BFS 最短路径 |
| 多跳路径 | A 到 B 所有路径（DFS） |
| 节点查询 | 任意值查邻居 |

---

## 5. 数据字典

见 `docs/01_field_dictionary.md`，关键约定：
- 聚合粒度为 device_id（uid/device_id 是别名）
- refund 粒度聚合后 join
- comp 字段统一口径为赔付

---

## 6. 验收标准

- 宽表 CSV 可正常加载（UTF-8, dtype=str 防科学计数法）
- 6 模型 + 7 规则 + 4 级分层全部输出
- 前端 6 个页签全部可用
- 社群路径可追溯（A→B 任意值查询）
- 高风险占比 1-5%

---

## 7. 风险与依赖

- 机票业务线已验证；酒店/门票需确认字段口径
- user_id 业务线口径需确认（若不一致需建 mapping 表）
- 伪标签阈值依赖人工抽检校准

---

## 8. 后续规划

- 接入 API 连接数据库，替代离线表输入
- 多业务线指标融合，检测交叉高风险
- 在线推理服务化
- 图神经网络（GNN）方向探索
