# 多模型对比 + 4 级风险分层

> 目标：把 865K 设备分到「高风险 / 中风险 / 疑似风险 / 普通用户」4 类
> 用多个模型对比 + 投票分层，既看每个模型结果也看综合结果
> 模型可解释：SHAP + 决策树 surrogate

---

## 一、为什么用多模型

单一模型有盲区：
- **Isolation Forest**：抓全局异常，但对局部聚集型异常弱
- **One-Class SVM**：对小样本边界敏感
- **LOF**：抓局部密度异常，但全量慢
- **XGBoost / LightGBM / RF**：监督学习精度高，但需要标签

方案：**无监督三模型 + 监督三模型 + 投票**，互相对比，互相印证。

---

## 二、监督模型标签怎么来

无正负样本 → 用**强规则生成伪标签**：

| 伪标签 | 条件 |
|---|---|
| 1（异常） | refund_rate≥0.5 AND refund_order≥5  OR comp≥500 AND multi_account  OR scalper≥1  OR is_machine_refund=1  OR distinct_user_id≥5  OR intercept≥2 |
| 0（正常） | refund=0 AND comp=0 AND user_id=1 AND scalper=0 AND intercept=0 AND pay_tool≤2 AND card≤2 |
| -1（未标记） | 其余，不参与监督训练 |

监督模型只学强置信样本，预测全量作为软标签。

---

## 三、模型清单

### 3.1 无监督（3 个）
| 模型 | 输出 | 优势 |
|---|---|---|
| Isolation Forest | score + label | 全局异常，快 |
| One-Class SVM (RBF) | score + label | 边界，可调 nu |
| LOF (novelty) | score + label | 局部密度异常 |

### 3.2 监督（3 个）
| 模型 | 输出 | 优势 |
|---|---|---|
| XGBoost | proba + pred | 高精度，SHAP 友好 |
| LightGBM | proba + pred | 快，类别不均衡友好 |
| RandomForest | proba + pred | 抗过拟合 |

### 3.3 可解释
- **SHAP TreeExplainer** → 对 XGBoost / LightGBM 算特征重要性
- **决策树 surrogate** → 拟合多模型投票结果，输出规则
- **模型相关性热力图** → 看哪些模型一致，哪些分歧

---

## 四、4 级分层规则

`vote = 各模型判定异常的票数（0-6）`，`rule_hit = 强规则命中数`

| 级别 | 条件 | 占比预期 |
|---|---|---|
| **高风险** | vote ≥ 60% AND rule_hit ≥ 2 | 1-3% |
| **中风险** | vote ≥ 2 AND rule_hit ≥ 1 | 5-10% |
| **疑似风险** | vote ≥ 1 OR rule_hit ≥ 1 | 15-25% |
| **普通用户** | 其余 | 60-80% |

阈值可调，初版基于数据分布。

---

## 五、输出文件

| 文件 | 说明 |
|---|---|
| `device_risk_score.csv` | 主输出：device_id + 4 级分层 + 6 个模型打分 |
| `model_comparison.txt` | 模型对比报告（各模型异常数、投票分布、分层结果） |
| `shap_global_importance.csv` | SHAP 全局特征重要性 |
| `shap_summary.png` | SHAP summary 图 |
| `shap_top10_anomaly.csv` | Top10 高风险设备 SHAP 局部解释 |
| `tree_rules.txt` / `tree_rules.png` | 决策树 surrogate 全局规则 |
| `model_correlation.png` / `.csv` | 6 模型相关性热力图 |
| `risk_level_distribution.png` | 4 级分布柱状图 |

---

## 六、运行

```bash
"D:/Users/yubotai.gao/coding/python/python.exe" python/08_multi_model_stratify.py
# 调试样本
"D:/Users/yubotai.gao/coding/python/python.exe" python/08_multi_model_stratify.py --sample 10000
```

输出目录：`data/model_output/`

---

## 七、对比维度

看模型结果时关注：
1. **各模型异常数**：iForest/OC-SVM/LOF/XGB/LGB/RF 各自标多少异常 → 看激进程度
2. **模型相关性**：高相关说明共识强，低相关说明互补
3. **SHAP 全局重要性**：top 特征是否稳定（退款率/多账号/赔付金额等）
4. **决策树规则**：可读规则是否与业务直觉一致
5. **4 级分布**：高风险占比是否合理（1-3%）

---

## 八、依赖
```
pandas numpy scikit-learn xgboost lightgbm shap igraph leidenalg matplotlib seaborn joblib
```
全部已装。
