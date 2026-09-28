# CodeRabbit 集成指南

## 什么是 CodeRabbit？

CodeRabbit 是一个 AI 驱动的代码审查工具，可以自动审查 Pull Request 并提供：
- 代码质量建议
- 潜在 bug 检测
- 架构合规性检查
- 性能优化建议

## 激活步骤

### 1. 安装 GitHub App

访问：https://github.com/apps/coderabbitai

点击 **"Install"** 或 **"Configure"**

### 2. 选择仓库

- 选择 **"Only select repositories"**
- 勾选 `MaoCreate-Wen/Wenlistener`
- 点击 **"Install"** 或 **"Save"**

### 3. 验证安装

安装成功后，CodeRabbit 会自动：
- 审查新创建的 PR
- 在 PR 中添加评论和建议
- 提供代码改进摘要

## 配置说明

本仓库的 CodeRabbit 配置文件：`.coderabbit.yaml`

### 主要配置项

- **语言**: 中文 (zh-CN)
- **审查模式**: chill（友好模式，不强制要求修改）
- **自动审查**: 启用（Draft PR 除外）
- **高级摘要**: 启用

### 路径规则

针对不同目录有专门的审查规则：

| 路径 | 检查重点 |
|------|----------|
| `lib/services/` | API 错误处理、网络重试、安全存储 |
| `lib/state/` | Provider 生命周期、内存泄漏 |
| `lib/pages/` | 分层架构合规性 |
| `android/` | 原生代码线程安全、权限 |
| `lib/animation/` | 性能、规格数值对齐 |

## 使用方式

### 创建 PR 时

1. 推送分支到 GitHub
2. 创建 Pull Request
3. 等待 CodeRabbit 自动审查（通常 1-2 分钟）
4. 查看审查评论并响应

### 与 CodeRabbit 交互

在 PR 评论中可以：

- `@coderabbitai 总结这个 PR` - 重新生成摘要
- `@coderabbitai 审查这个文件` - 针对特定文件审查
- `@coderabbitai 解释这段代码` - 请求代码解释
- `@coderabbitai pause` - 暂停审查
- `@coderabbitai resume` - 恢复审查

## 项目特定规则

CodeRabbit 已配置了解本项目的架构约束：

✅ **会检查的**
- 页面是否违反分层规则（pages 直接 import services）
- release 包的资源 keep 配置
- 版本号是否正确递增
- 动画数值是否符合 AMLL 规格

❌ **不会误报的**
- 四音源架构的特殊设计
- MusicSource.migu 槽位装 QQ 音乐（已知设计）
- FFT 律动的原生通道实现

## 注意事项

1. **首次审查可能较慢**：CodeRabbit 需要学习项目结构
2. **Draft PR 不审查**：避免干扰开发中的代码
3. **可以忽略建议**：chill 模式不会阻止合并
4. **隐私保护**：代码不会用于训练模型

## 故障排查

### CodeRabbit 没有审查我的 PR

- 检查是否是 Draft PR（配置中已禁用）
- 确认 GitHub App 权限已授予
- 查看 PR 的 Checks 标签页是否有错误

### 审查语言不是中文

- 检查 `.coderabbit.yaml` 中 `language: zh-CN`
- 重新触发审查：关闭并重新打开 PR

### 想要更严格的审查

修改 `.coderabbit.yaml`：
```yaml
reviews:
  profile: assertive  # 改为 assertive 模式
  request_changes_workflow: true  # 启用强制修改
```

## 相关链接

- [CodeRabbit 官方文档](https://docs.coderabbit.ai/)
- [配置参考](https://docs.coderabbit.ai/guides/configure-coderabbit/)
- [命令列表](https://docs.coderabbit.ai/guides/review-instructions/)

---

配置完成后，下次创建 PR 时 CodeRabbit 就会自动开始工作！
