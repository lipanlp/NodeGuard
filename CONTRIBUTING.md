# 参与开发

需要 macOS、Apple Command Line Tools 和 Python 3（仅模拟接口测试使用）。依赖源码随仓库提供，来源与许可证见 [第三方组件](docs/THIRD-PARTY.md)。

```sh
./scripts/build.sh
./scripts/test.sh
python3 scripts/mock-api-test.py
./scripts/package.sh
python3 scripts/verify-dmg.py
```

应用、DMG 和源码包生成在 `outputs/`；编译缓存和测试中间文件在 `work/`，均不提交到 Git。

## 修改与验证

- 保持原生 Swift 实现，控制体积、后台 CPU、缓存和依赖数量。
- 用注入的信号发送器及临时假 Unix API 测试。开发验收不要结束真实 Claude、切换真实前置节点，或修改 Clash 的订阅、规则、DNS 与代理定义。
- 需要查看本机运行状态时使用 `--observe-only`。普通构建和模拟测试不代表真实故障切换、Claude 强退或长期稳定性已经验收。
- 按修改范围运行相关检查；提交时说明行为变化、验证方法和未验证边界。

## 提交问题

请提供应用版本、macOS/Clash Verge 版本、复现步骤和脱敏后的错误分类。发布前自行检查截图与诊断文件。

不要上传原始 Clash 配置、订阅链接、代理凭据、锁定 IP、聊天内容、`state.json` 或 `work/`。测试凭据使用明显的假值，域名使用 `example.org`、`example.invalid` 等示例域名。

提交代码即表示你有权按本项目的 MIT 许可证贡献这些代码；第三方代码应保留其原有许可与来源。
