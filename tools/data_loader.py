# data_loader.py — 数据文件自动发现与兜底输入（所有 notebook 共用）
# 规则：
#   1. data/ 下按命名规范找 XX.XX.XX_base.csv / XX.XX.XX_detail.csv（日期前缀，支持 26.08.27 / 2026-08-27 两种格式）
#   2. base 与 detail 优先取「同日期」里的最新日期；无同日期配对时各自取最新，并打印警告
#   3. 找不到时让用户 input 文件名（兜底），文件必须存在于 data/ 下
#   4. IP地址.xlsx 同理：存在即用，不存在返回 None（页签显示无名单）
import os
import re
import glob

DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")

_DATE_PAT = re.compile(r"^(\d{2}\.\d{2}\.\d{2}|\d{4}-\d{2}-\d{2})_")


def _date_key(prefix):
    """'26.08.27' -> '2026-08-27'；'2026-08-27' 原样。无法解析返回 ''（排最后）"""
    m = re.match(r"^(\d{2})\.(\d{2})\.(\d{2})$", prefix)
    if m:
        return "20%s-%s-%s" % m.groups()
    return prefix if re.match(r"^\d{4}-\d{2}-\d{2}$", prefix) else ""


def find_latest(pattern):
    """在 data/ 下找 pattern（如 '*_base.csv'），按日期前缀返回最新文件名；无则 None"""
    files = [os.path.basename(p) for p in glob.glob(os.path.join(DATA_DIR, pattern))]
    dated = []
    for f in files:
        m = _DATE_PAT.match(f)
        if m:
            dated.append((_date_key(m.group(1)), f))
    if not dated:
        return None
    dated.sort()
    return dated[-1][1]


def resolve_base(prompt=True):
    """找最新 base 宽表。找不到时提示用户输入文件名。"""
    f = find_latest("*_base.csv")
    if f is None and prompt:
        f = _ask_input("base")
    if f is None:
        raise FileNotFoundError("data/ 下未找到 *_base.csv，且用户未提供文件名")
    print(f"[data_loader] base 宽表: {f}")
    return os.path.join(DATA_DIR, f)


def resolve_detail(base_name=None, prompt=True):
    """找 detail 明细。优先与 base 同日期配对；无配对取最新并警告；找不到提示输入。"""
    det = find_latest("*_detail.csv")
    if det is None and prompt:
        det = _ask_input("detail")
    if det is None:
        raise FileNotFoundError("data/ 下未找到 *_detail.csv，且用户未提供文件名")
    # 同日期配对检查
    if base_name:
        b_date = _DATE_PAT.match(base_name)
        d_date = _DATE_PAT.match(det)
        if b_date and d_date and _date_key(b_date.group(1)) != _date_key(d_date.group(1)):
            print(f"[data_loader][警告] base({b_date.group(1)}) 与 detail({d_date.group(1)}) 日期不一致！"
                  f"已按各自最新日期执行，请确认口径")
    print(f"[data_loader] detail 明细: {det}")
    return os.path.join(DATA_DIR, det)


def resolve_ip_list():
    """IP 黑名单 Excel：存在即用（不写死 IP），不存在返回 None"""
    p = os.path.join(DATA_DIR, "IP地址.xlsx")
    return p if os.path.exists(p) else None


def _ask_input(kind):
    """兜底：让用户输入 data/ 目录下的文件名"""
    print(f"[data_loader] 未按命名规范找到 {kind} 文件（应为 XX.XX.XX_{kind}.csv）")
    avail = [os.path.basename(x) for x in glob.glob(os.path.join(DATA_DIR, "*.csv"))][:20]
    if avail:
        print(f"[data_loader] data/ 下现有 CSV: {', '.join(avail)}")
    try:
        name = input(f"[data_loader] 请输入 {kind} 文件名（直接回车取消）: ").strip()
    except EOFError:
        return None
    if not name:
        return None
    p = os.path.join(DATA_DIR, name)
    while not os.path.exists(p):
        try:
            name = input(f"[data_loader] 文件 {name} 不存在，请重新输入（回车取消）: ").strip()
        except EOFError:
            return None
        if not name:
            return None
        p = os.path.join(DATA_DIR, name)
    return name


if __name__ == "__main__":
    # 自测
    print("=== data_loader 自测 ===")
    b = resolve_base(prompt=False)
    d = resolve_detail(base_name=os.path.basename(b) if b else None, prompt=False)
    print("IP 名单:", resolve_ip_list())
