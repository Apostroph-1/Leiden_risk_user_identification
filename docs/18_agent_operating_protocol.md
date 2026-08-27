# Agent 操作协议

> 本文件是接手此项目的 AI agent 必须遵守的操作约束清单。
> 在执行任何代码修改前，先完整阅读本文件。
> 项目背景见 docs/17_agent_handoff_SOP.md，先读那个文件再读本文件。

---

## 第零条：启动检查

每次开始工作前，依次执行以下检查：

1. 确认当前工作目录在项目根目录
2. 确认 git 仓库状态干净（git status 无未提交改动，除非是用户主动改的）
3. 确认 data/ 目录存在且包含必要文件
4. 确认 Docker 容器或本地 Python 服务在运行（http://localhost:8766 可访问）
5. 先读 docs/17_agent_handoff_SOP.md 了解项目全貌

---

## 第一条：硬性约束（不可违反）

### 1.1 编码与 Shell

- **PowerShell 会把中文输出变成乱码**（GBK 编码问题）。文件内容本身没问题，只是终端显示乱码。不要因为看到乱码就认为文件坏了。
- **能用 Python 完成的事情一律用 Python**，不用 PowerShell 做文本处理、文件拼接、base64 编码等操作。
- **所有 CSV 输出用 UTF-8 + 逗号分隔**，写入时指定 ncoding='utf-8-sig'。
- **所有命令执行用 equire_escalated** 绕过 sandbox 限制，不要反复尝试 sandbox 失败再切换。
- **apply_patch 对已存在的文件经常失败**，遇到这种情况改用 Python 脚本读写文件，执行完后立即删除该脚本。

### 1.2 代码组织

- **不创建冗余 .py 文件**。所有核心代码放在 
otebooks/XX_cells.txt 中，用 
b_generator.py 生成 .ipynb。
- **临时 Python 脚本用完立即删除**，不留任何 .py 文件在项目根目录或 python/ 目录。
- **cells.txt 格式**：##MD## 标记 markdown cell，##CODE## 标记 code cell。修改 cells.txt 后必须重新生成 .ipynb。
- **notebook 中可调参数处必须写注释**，标明：参数名、当前值、修改范围、修改后影响什么。

### 1.3 数据处理

- **读取 CSV 一律用 pd.read_csv(path, dtype=str)**，不自动检测类型，防止 device_id 变成科学计数法。
- **原始数据中的脏数据（null、nan、None、"null"、" "、空字符串）必须在 Leiden 前清除**。
- **data/ 目录不进 Git，不进 Docker 镜像**。通过 .gitignore 排除，Docker 通过 volume 挂载。
- **新增数据文件放在 data/ 目录下**，不要放在项目根目录。

### 1.4 前端规范

- **色系固定用 Tableau 10**，不要换其他配色。
- 节点颜色：设备号=#4E79A7(蓝)，用户ID=#F28E2B(橙)，支付索引=#59A14F(绿)，乘机人证件=#E15759(红)，乘机人手机=#B07AA1(紫)。
- **前端界面自适应布局**，画布大小可调整，节点不会走出窗口就消失。
- **下钻交互**：社区 -> 设备明细 -> 涉及的 user_id / pay_tool / 证件 / 手机明细。
- **搜索功能**：社区指标和高危分析都要有搜索社区 ID 的能力。

---

## 第二条：每次修改的完整流程

每次用户要求修改代码时，必须按以下步骤执行，**不可跳过任何一步**：

### 步骤 1：理解需求
- 确认用户要改什么（notebook / server / 前端 / 规则 / 模型参数）
- 确认改动的范围和影响面

### 步骤 2：修改代码
- 修改对应的 cells.txt / community_server.py / community_viz.html
- 如果改了 cells.txt，运行 python notebooks/nb_generator.py 重新生成 .ipynb
- **不要用 apply_patch 改 .ipynb 文件**（JSON 格式容易出错），改 cells.txt 后用 nb_generator 生成

### 步骤 3：验证
- 如果改了 notebook：在 VSCode 中逐 cell 执行确认无报错
- 如果改了 server.py：重启服务，确认 http://localhost:8766 正常
- 如果改了前端 HTML：刷新浏览器确认页面正常
- 用 Python 验证数据输出正确（dtype=str 读取，检查行列数和关键列）

### 步骤 4：代码评审
- 检查改动是否引入了 bug
- 检查是否有遗漏的边界情况（空值、极大值、极小值）
- 检查编码是否一致（UTF-8）
- 检查是否有冗余代码或未清理的临时文件
- 更新 docs/10_notebook_code_review.md（如果是 notebook 改动）

### 步骤 5：更新文档（按改动类型选择）
根据改动内容，更新以下文档（**不是全改，按需改**）：

| 改动类型 | 需更新的文档 |
|----------|-------------|
| 模型参数 / 规则 / 分层逻辑 | docs/03_PRD.md, docs/08_multi_model_stratification.md, docs/11_workflow_SOP.md |
| Leiden 算法 / 社区检测 | docs/03_PRD.md, docs/11_workflow_SOP.md |
| 前端功能 / API | docs/03_PRD.md, docs/17_agent_handoff_SOP.md 的 API 清单 |
| 新增字段 / 新增指标 | docs/01_field_dictionary.md, docs/02_field_design.md, docs/12_cross_bizline_metrics_design.md |
| Docker / 环境配置 | docs/16_docker_deployment.md, README.md |
| Agent 操作流程 | docs/18_agent_operating_protocol.md（本文件） |
| 任何改动 | README.md 中的版本号和改动说明 |

### 步骤 6：Git 提交
`ash
git add -A
git commit -m "vX.Y: 简要描述改动"
git push origin main
`
- commit message 格式：X.Y: 中文描述
- **data/ 目录不会被提交**（.gitignore 排除）
- 确认 push 成功，如果失败检查是否有大文件（>100MB 会被 GitHub 拒绝）

### 步骤 7：向用户汇报
- 告诉用户改了什么、验证结果、commit hash
- 如果有后续建议，简短提及

---

## 第三条：文档更新规则

### 3.1 必须更新的文件

每次改动后，以下文件必须检查是否需要更新：

| 文件 | 何时更新 | 更新什么 |
|------|----------|----------|
| README.md | 每次改动 | 版本号、改动摘要、模型参数表、规则表、风险分层表 |
| docs/03_PRD.md | 功能/规则/模型变更 | 需求描述、功能清单、参数配置 |
| docs/11_workflow_SOP.md | 流程变更 | 操作步骤、执行命令、耗时估计 |
| docs/10_notebook_code_review.md | notebook 改动 | 评审结果、问题列表、修复记录 |

### 3.2 按需更新的文件

| 文件 | 触发条件 |
|------|----------|
| docs/01_field_dictionary.md | 新增/修改字段 |
| docs/08_multi_model_stratification.md | 模型参数变更 |
| docs/12_cross_bizline_metrics_design.md | 新增业务线指标 |
| docs/15_community_behavior_analysis.md | 社区分析逻辑变更 |
| docs/16_docker_deployment.md | Docker 配置变更 |
| docs/17_agent_handoff_SOP.md | API 新增/变更 |

### 3.3 README 版本号规则

- 小改动（bug fix、注释）：vX.Y+1
- 功能新增（新规则、新页签）：vX+1.0
- 当前版本：v2.4

---

## 第四条：验证与测试清单

### 4.1 Notebook 改动后验证

`python
# 用 Python 验证输出数据
import pandas as pd
df = pd.read_csv('data/model_output/device_risk_score.csv', dtype=str)
print(f'行数: {len(df)}')
print(f'列数: {len(df.columns)}')
print(f'列名: {list(df.columns)}')
print(f'风险分层分布:\n{df["risk_level"].value_counts()}')
print(f'规则命中:\n{df[["is_short_refund_strong","is_short_refund_weak","is_machine_refund","is_night_heavy","is_multi_account","is_multi_pay_tool","is_multi_passenger"]].sum()}')
`

### 4.2 前端改动后验证

- 打开 http://localhost:8766 确认页面加载
- 检查 6 个页签都能正常切换
- 检查搜索功能正常
- 检查下钻交互正常（社区 -> 设备 -> 明细）
- 检查图谱渲染正常（节点不会消失）

### 4.3 Docker 改动后验证

- docker compose build 成功
- docker compose up -d 成功
- docker logs leiden-server-1 显示正常启动日志
- http://localhost:8766 返回 HTTP 200

---

## 第五条：已知踩坑清单

### 5.1 编码相关

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| PowerShell 中文输出乱码 | Windows 终端用 GBK 编码 | 文件内容没问题，忽略终端显示；或用 Python 处理 |
| apply_patch 改已有文件失败 | 文件 hash 不匹配 | 用 Python 脚本读写文件后删除脚本 |
| .dockerignore 文件改不动 | reparse point 属性 | 用 cmd /c del /f /q 删除后重建 |

### 5.2 数据相关

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| device_id 变科学计数法 | pandas 自动推断数值类型 | pd.read_csv(path, dtype=str) |
| 社区 ID 变科学计数法 | 同上 | 同上 |
| Leiden 结果中出现 null 连线 | 原始数据有脏值 | 清除 null/nan/None/"null"/" " 后再构建图 |
| 输出 CSV 有 BOM 头 | encoding='utf-8-sig' | 读取时用 'utf-8-sig' 或 'utf-8' |

### 5.3 Docker 相关

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| Docker Desktop "virtualisation not detected" | Windows HVCI 占用 VT-x | 关闭内存完整性（Windows 安全中心 -> 设备安全性 -> 内核隔离） |
| Docker build "failed to fetch anonymous token" | 国内无法连 Docker Hub | 配置镜像加速器（daemon.json） |
| Docker 崩溃 "sailor-ingest.sock cannot be accessed" | 残留 Unix socket 文件 | cmd /c del /f /q 删除残留文件后重启 |
| COPY .gitignore 失败 | .dockerignore 排除了 .gitignore | Dockerfile 中移除该 COPY 行 |

### 5.4 Git 相关

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| push 被拒绝 "Large files detected" | data/ 下有大文件 | 确认 .gitignore 排除了 data/*.csv 和 data/*.xlsx |
| commit 包含了 data 文件 | git add -A 会暂存所有 | .gitignore 必须先配好再 add |

---

## 第六条：Git 提交规范

### commit message 格式

`
vX.Y: 简要描述

- 改动点 1
- 改动点 2
`

### 版本号递进

- v2.4 -> v2.5：bug 修复、参数微调、注释补充
- v2.4 -> v3.0：新功能、新规则、新业务线、新前端模块

### 禁止事项

- 不要 git reset --hard 除非用户明确要求
- 不要 revert 不是自己做的改动
- 不要 force push
- 不要提交 data/ 下的任何文件

---

## 第七条：与用户的沟通方式

1. **用中文回复**，技术术语可以用英文。
2. **操作步骤要写下来**，用户在学习如何操作，不只是要结果。
3. **每次操作前说明要做什么**，操作后说明结果。
4. **遇到问题先尝试自己解决**，不要动不动就问用户。如果确实需要用户决策（如关闭安全设置、重启电脑），明确告知风险和影响。
5. **不要用 macOS 终端做复杂操作**，能用 Python 就用 Python。
6. **用户喜欢逐步操作**，不要一口气做完所有事不解释。按最小步骤操作，每步说清楚。

---

## 第八条：项目当前状态快照

- 版本：v2.4
- Git 最新 commit：见 git log --oneline -1
- 数据规模：865K 设备，440K 节点（Leiden 图），24K 社区
- 风险分布：高风险 3.0%，中风险 23.3%，疑似 60.3%，普通 13.4%
- Docker 镜像：已构建，leiden-server:latest
- 前端服务：端口 8766，6 个页签
- 训练环境：Windows（Core Ultra 7 165H, 32GB RAM）
- 展示环境：Mac mini（i7-8700, 16GB RAM）或任意能跑 Docker 的机器
