# coding: utf-8
"""生成音素热词用的汉字→tone3 拼音字典 asset。

数据源：pypinyin（CapsWriter-Offline 音素热词同款库，底层数据同 mozillazg/pinyin-data，
MIT 许可）——用同一套数据才能保证本 APP 的音素结果与 CapsWriter 严格一致。

对齐 CapsWriter 的调用参数（core/client/hotword/algo_phoneme.py::_process_zh）：
- Style.TONE3：输出带数字声调的拼音，如 han4、zhong1
- neutral_tone_with_five=True：轻声记 5（CapsWriter 同款，缺省是记 0）
- errors='ignore'：pypinyin 不认识的字返回原字符——数字结尾校验不过时
  本脚本直接不写该字，运行时整字兜底（与 CapsWriter 降级行为一致）

用法：uv run --with pypinyin tools/pinyin/gen_pinyin_dict.py
输出：assets/pinyin_dict.txt（每行 `字=han4`，UTF-8）
"""

import sys
from pypinyin import pinyin, Style

ASSET_PATH = "assets/pinyin_dict.txt"

# 声母表（pypinyin Style.INITIALS strict=False 的等价拆分依据，最长匹配优先）
INITIALS = [
    "zh", "ch", "sh",
    "b", "p", "m", "f", "d", "t", "n", "l",
    "g", "k", "h", "j", "q", "x", "r", "z", "c", "s",
    "y", "w",
]


def main() -> None:
    lines = []
    skipped = []
    for cp in range(0x4E00, 0x9FFF + 1):
        ch = chr(cp)
        py = pinyin(ch, style=Style.TONE3, neutral_tone_with_five=True,
                    errors="ignore")
        if py and py[0] and py[0][0] and py[0][0][-1].isdigit():
            lines.append(f"{ch}={py[0][0]}")
        else:
            skipped.append(ch)

    # newline='\n' 强制 LF：Windows 默认会把 \n 翻译成 \r\n，行尾 \r 会让
    # Dart 侧 tone3 尾字符校验（isdigit）全部失败、整表退化为整字兜底
    with open(ASSET_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print(f"共 {len(lines)} 字入字典，{len(skipped)} 字无读音被跳过")
    if skipped:
        print("跳过样本:", "".join(skipped[:40]))

    # 代表性字符自检（值为 pypinyin 权威输出，同时作为 lib/hotword 单测的
    # 对拍基准：test/phoneme_hotword_test.dart 断言同字符同音素）
    checks = {
        "安": "an1",     # 零声母（无声母，整节就是韵母）
        "呀": "ya5",     # 语气词默认轻声记 5（pypinyin 权威行为）
        "中": "zhong1",  # 翘舌声母 zh
        "国": "guo2",
        "汉": "han4",
        "长": "zhang3",  # 多音字取 pypinyin 默认读音（长江 chang2 需热词别名兜底）
        "的": "de5",     # 轻声记 5
        "了": "le5",
        "乐": "le4",
        "次": "ci4",     # 平舌
        "握": "wo4",     # w 声母
        "英": "ying1",   # 后鼻音韵母 ing
        "闻": "wen2",
    }
    got = dict(line.split("=") for line in lines)
    failed = {k: (v, got.get(k)) for k, v in checks.items() if got.get(k) != v}
    if failed:
        for k, (want, actual) in failed.items():
            print(f"✗ {k}: 期望 {want} 实际 {actual}")
        sys.exit(1)
    print(f"✓ 代表性字符自检 {len(checks) - len(failed)}/{len(checks)} 通过")


if __name__ == "__main__":
    main()
