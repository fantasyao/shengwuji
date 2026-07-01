# 异步操作与加载状态

## 核心原则

在实现 UI 加载状态时，**绝不要**在显示加载覆盖层之前用异步操作阻塞主线程。

## 正确模式

```dart
// 1. 先设置加载状态
setState(() {
  _isLoading = true;
});

// 2. 然后执行繁重的异步工作
await heavyAsyncOperation();

// 3. 最后清除加载状态
setState(() {
  _isLoading = false;
});
```

### 常见场景

#### 模型加载
```dart
Future<void> loadModel() async {
  setState(() {
    _isLoading = true;
    _loadingMessage = '加载语音识别模型...';
  });

  try {
    await recognizer.loadModel();
  } finally {
    setState(() {
      _isLoading = false;
    });
  }
}
```

#### 语音识别
```dart
Future<void> recognizeAudio() async {
  setState(() {
    _isRecognizing = true;
  });

  try {
    final result = await recognizer.recognize(audioData);
    processResult(result);
  } finally {
    if (mounted) {
      setState(() {
        _isRecognizing = false;
      });
    }
  }
}
```

## 错误模式

```dart
// ❌ 错误：阻塞 UI 更新
await heavyAsyncOperation(); // 耗时操作完成前界面卡住
setState(() {
  _isLoading = true; // 加载状态显示太晚
});
```

## 最佳实践

### 1. 使用 finally 确保状态重置
```dart
setState(() {
  _isLoading = true;
});

try {
  await operation();
} catch (e) {
  handleError(e);
} finally {
  if (mounted) {  // 检查 widget 是否还在树中
    setState(() {
      _isLoading = false;
    });
  }
}
```

### 2. 检查 mounted 状态
在异步操作后更新 UI 前，始终检查 `mounted` 标志：
```dart
if (mounted) {
  setState(() {
    // 更新状态
  });
}
```

### 3. 提供有意义的加载消息
```dart
setState(() {
  _isLoading = true;
  _loadingMessage = '正在初始化语音识别...';
});
```

### 4. 分阶段加载
对于多个异步操作，考虑分阶段更新加载消息：
```dart
setState(() {
  _loadingMessage = '加载模型... (1/3)';
});
await loadModel();

setState(() {
  _loadingMessage = '初始化录音器... (2/3)';
});
await initRecorder();

setState(() {
  _loadingMessage = '准备就绪... (3/3)';
});
await prepare();
```

## 相关文档
- @architecture/state-management.md - 状态管理架构
- @architecture/speech-recognition.md - 语音识别流程
