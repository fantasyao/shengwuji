# 延迟模型加载 Bug 修复复盘

## 背景

原始需求：App 启动时不加载语音识别模型，用户录完音后再加载，减少启动卡顿。

这个功能在 2026 年 1 月的提交 `b3f057d` 中已经实现过，后来因为太卡改回了启动时加载。2026 年 4 月重新实现时，引入了 5 个串联 bug，导致日记页录音完全不可用。

---

## Bug 清单

### Bug 1：按钮控制点找错了

**现象**：修改了 `diary_tab.dart` 的 `btnColor` 变量，按钮颜色不变。

**根因**：日记页的浮动录音按钮不在 `diary_tab.dart` 的 build 方法中，而在 `main.dart` 的 `_buildFloatingDiaryButton()` 方法中。`diary_tab.dart` 中的 `btnColor`、`btnChild`、`onBtnPressed` 是 **unused 局部变量**，IDE 已经通过 warning 提示了。

**教训**：
- 修改 UI 状态前，必须确认控制点在哪。用 IDE 搜索变量引用，不要想当然。
- **IDE 的 warning 不是噪音**。`unused variable` 意味着你改的东西根本没生效。

### Bug 2：`hasModel` 依赖未初始化的变量

**现象**：用户导入模型后，`hasModel` 仍返回 `false`。

**根因**：`RecognizerSingleton.hasModel` 依赖 `_currentModelPath` 判断文件是否存在，但 `_currentModelPath` 只在 `initialize()` 成功后才被赋值。`hasModel` 的设计意图是"不加载模型，只检查文件是否存在"，但实现上依赖了一个只有加载模型后才有的值——逻辑矛盾。

此外，`preloadModelPath()` 有缓存检查 `if (_currentModelPath != null) return`，首次启动后 `_currentModelPath` 为 null，用户导入模型后不会重新读取。

**教训**：
- **读写分离**："检查是否存在"和"加载到内存"是两个独立操作，不能共享同一个状态变量。
- **方法语义要自洽**：名叫 `hasModel` 却依赖"模型已加载"的变量，名字和行为不一致。

### Bug 3：`stopListening` 中识别器为空时提前返回

**现象**：录完音后没有任何输出，没有任何错误提示。

**根因**：`diary_tab.dart` 的 `stopListening()` 第 788 行有：
```dart
if (_recognizer == null || isProcessing) {
  return;  // 识别器为空直接返回
}
```
延迟加载的设计意图是"录完音后在 stopListening 中加载模型"，但这段代码在加载模型之前就因为 `_recognizer == null` 而 return 了，后面的加载代码永远执行不到。

**教训**：
- **代码逻辑和设计意图矛盾时，代码会赢**。改了设计意图（延迟加载），就要检查所有依赖旧行为的守卫代码。
- **删代码比加代码更危险**。这行守卫在"启动时加载模型"的模式下是正确的，模式变了它就成了 bug。

### Bug 4：`initEngine` 因 `isProcessing` 跳过加载

**现象**：即使修复了 Bug 3，模型仍然加载不了。

**根因**：`stopListening` 在调用 `initEngine()` 之前，先把 `isProcessing` 设为 `true`。而 `initEngine()` 检查 `if (isProcessing || isReady) return`，一进来就因为 `isProcessing == true` 直接返回。

调用链：
```
stopListening() {
  isProcessing = true;        // 第 1 步：设为 true
  ...
  initEngine() {
    if (isProcessing) return;  // 第 2 步：检测到 true，直接返回！
  }
}
```

**教训**：
- **跨方法的状态变量有隐式依赖**。改一个方法的逻辑时，必须检查它调用的方法是否依赖同一个状态变量。
- **设状态和用状态的顺序很重要**。`isProcessing = true` 的目的是显示 UI 状态，但它也成了 `initEngine` 的守卫条件。

### Bug 5：录音权限没有请求

**现象**：AudioRecord 报错 `status: -1`，录音失败。

**根因**：旧的流程中，`initState` 会调 `_initEngine()`，里面会请求麦克风权限。改为延迟加载后不再自动调 `_initEngine()`，权限请求也被跳过了。

**教训**：
- **权限请求不能绑定在可选流程上**。如果某个功能需要权限，权限请求应该在用户触发该功能时发起，而不是绑定在初始化流程中。

---

## 错误路线分析：为什么会走这么多弯路

### 根本原因：没有读完整个调用链就开始改

每次只看了一个文件就下结论：
1. 改了 `diary_tab.dart` → 没发现按钮在 `main.dart` 里
2. 改了 `recognizer_singleton.dart` → 没发现 `preloadModelPath` 需要在多处调用
3. 修了 `_recognizer == null` → 没发现 `isProcessing` 也会阻止加载

每次修了一个 bug，立刻暴露下一个。如果一开始就把完整调用链读一遍，这些问题在第一次就能发现。

### 正确的做法

修改涉及状态流转的逻辑时，应该：
1. **列出所有使用该状态变量的地方**（用 IDE 的 `Find Usages`）
2. **画出状态流转图**：`isReady`、`isProcessing`、`_recognizer` 在哪些方法中被读、写
3. **逐个检查每个读写点**在新模式下是否还正确

---

## 一句话修复模板

以后遇到类似的"状态/流程变更导致多处不兼容"问题，用这句话：

> **"我要修改 [具体功能]。请先用 Grep 搜索所有引用了 [关键状态变量/方法名] 的地方，列出完整的调用链后再修改。"**

例如这次的情况：

> "我要把模型加载从启动时改为录音后延迟加载。请先搜索所有引用了 `isReady`、`_recognizer`、`isProcessing`、`_initEngine`、`hasModel` 的地方，画出完整的状态流转图，列出所有受影响的代码点后再修改。"

这样可以在第一次就把所有 bug 点找出来，而不是修一个爆一个。
