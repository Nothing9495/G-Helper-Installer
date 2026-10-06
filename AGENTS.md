# AGENTS.md

本仓库是 [seerge/g-helper](https://github.com/seerge/g-helper) 的 fork，额外提供
Inno Setup 安装程序、自包含打包与 GitHub Actions 发布。上游代码保持可合并。

## 项目目标

| | |
|---|---|
| `main` | 上游 `seerge/g-helper` 的**纯净镜像**，不做任何自有改动 |
| `installer-release` | 发布分支，也是全部开发所在（GitHub 默认分支仍是 `main`） |
| 产物 | 仅 `GHelper-v<tag>-Setup.exe`（Inno Setup），无 portable zip |
| 上游同步 | 不追最新，按上游 tag 逐个窗口人工合并 |

## 项目约束

- **`app/` 尽量少改。** 每多改一行，上游合并就多一分冲突。当前改动 6 个文件，其中
  `ServiceCli.cs` 是全新文件（136 行，零冲突）；**真正插进上游文件的只有约 78 行改动**，
  且集中在 `AutoUpdateControl.cs` 一个方法内。清单与冲突风险评级见
  `docs/installer/git-manual.md` §6。新增能力优先放进新文件，不要散落进上游文件。
- **构建脚本不碰 Git。** `build.ps1` 只负责构建；`build.ps1` 里出现 `git` 即为错误。
- **分支合并完全人工。** 不写 `sync-upstream` 类 workflow，不做自动开 PR。
- **workflow 只负责 CI 与构建发布**，不含任何 Git 写操作。
- 本机不使用远程构建（无 `devvm-build.json`）。

## Git 管理约束

完整规则见 `docs/installer/git-manual.md`，以下是速查。

### 同步上游

```powershell
git checkout main; git fetch upstream; git merge --ff-only upstream/main; git push origin main
git checkout installer-release
git log main --format=%H --grep="^Version bump$"   # 列出所有版本边界
git merge --no-ff --no-edit -m "Merge upstream tag v0.287 (2ca868a0)" <边界SHA>
git push origin installer-release
git tag -a v0.287 -m "..."; git push origin v0.287
```

### 如何查询版本边界

上游每个 release 有一个 `Version bump` 提交，且该提交修改 `AssemblyVersion`。
用 `main` 的历史推导，**不要获取上游 tag**：

```powershell
git log main --format=%H --grep="^Version bump$" | ForEach-Object {
    $csproj = (git show "${_}:app/GHelper.csproj") -join "`n"
    "{0,-10} {1}" -f ([regex]'<AssemblyVersion>([^<]+)<').Match($csproj).Groups[1].Value, $_.Substring(0,8)
}
```

上面这段可直接运行，输出形如 `0.286      900e6a51`（版本号 + 边界 commit）。
注意 `git log main` 只给出**本地已知**的边界；要包含尚未 fetch 的上游版本，先更新 `main`。

### 不被允许

- ❌ `git fetch upstream --tags` / `git fetch --tags` / `refs/upstream-tags/*`
  （本 fork 的发布 tag 与上游同名，引入上游 tag 对象必然冲突）
- ❌ 合并 `main` 的 HEAD —— 它领先于最新 tag，会夹带未发布的上游提交
- ❌ 在 `main` 上 commit / tag / 改文件
- ❌ 非 `v<数字>.<数字>` 格式的 tag（`AutoUpdateControl` 用 `Replace("v","")` 解析，全局替换会吃掉 `preview` 里的 v）
- ❌ 改动产物文件名而不改客户端查找名（见下）

### 合并后的人工核对

```bash
git log --oneline installer-release ^main    # 有输出=夹带了未打 tag 的上游提交
```

`git rev-list --merges -1` 会命中**上游自带**的 merge commit，审计窗口时必须用
`git log --merges --grep="Merge upstream tag" -1`。

## 构建

单一入口，CI 与本地共用：

```powershell
.\build.ps1                    # 完整：publish + ISCC
.\build.ps1 -SkipPublish       # 只跑 ISCC，改 .iss 时用（快很多）
.\build.ps1 -SkipSetup         # 只 publish
.\build.ps1 -Tag v0.286        # CI 用；不匹配 AssemblyVersion 会失败
.\build.ps1 -Iscc <绝对路径>   # CI 用
```

- 必须用 `dotnet publish app/GHelper.csproj`，**不能用 `.sln`** —— sln 级 `-o` 会触发 NETSDK1194 警告
- 发布必须 `-p:PublishSingleFile=false`：松散目录 + `lzma2/max`，实测 312 文件 / 122.7 MB → 37.2 MB
- ISCC 必须传 `-Iscc`（CI 里 machine 级安装不刷新 PATH）

### 构建期自动检查

`build.ps1` 内置两项防护，改 `.iss` 时留意：

1. **`[Code]` 段内任何行首为 `[` 都会报 `Invalid section tag`** —— 包括注释里。这个坑踩过 3 次，
   所以脚本会在编译前扫描并给出精确行号。
2. payload 文件数 < 50 视为异常（publish 静默降级为非自包含）。

## Inno Setup 陷阱（7.1.0 实测）

按需查阅 `docs/installer/pitfalls.md`，以下几条最容易再犯：

| 现象 | 真实规则 |
|---|---|
| `Cannot call "CreateInputOptionPage" during UnInstall` | 卸载期禁止建向导页，改用 `MsgBox` |
| `Cannot call "WizardSilent" during UnInstall` | 安装期用 `WizardSilent`，卸载期用 `UninstallSilent` |
| `CustomMessagesFile` 不被识别 | 该指令不存在；用 `[CustomMessages]` + 语言前缀，前缀是 `[Languages]` 的完整 `Name`（`chinesesimplified.`），**不能**写 `en.` |
| `[Tasks]` 报 Invalid section tag | **Inno 不允许重复段**，必须合并 |
| `#define` 在 `[Code]` 中不展开 | 必须写 `'{#MyDefine}'` |
| `Type: dirs` 报 not a valid value | `[UninstallDelete]` 只接受 `files` / `filesandordirs` |
| `BoolToStr` / `IIf` / `GetCommandTail` / `CmdLineParamExists` | 这些标识符在 7.1.0 **不存在** |
| `PrepareToInstall` 原型不符 | 是返回 `String` 的**函数**，非空返回即中止安装 |

## 契约：产物文件名

`GHelper-{tag}-Setup.exe` 三处必须一致：

1. `installer/GHelper.iss` → `OutputBaseFilename=GHelper-v{#MyAppVersion}-Setup`
2. `app/AutoUpdate/AutoUpdateControl.cs` → `expectedAsset := $"GHelper-{tagName}-Setup.exe"`
3. `.github/workflows/build-installer.yml` → `dist/GHelper-${{ steps.tag.outputs.value }}-Setup.exe`

改名会**静默**破坏自动更新（客户端降级打开 releases 页，不报错）。

## 其他高价值信息

### 安装器行为

- `PrivilegesRequired=admin`（禁服务 + 写 `{autopf}` 都需要）
- `StopRunningGHelper`：优雅退出（`Global\GHelperApp-Exit` 事件）→ 等 3 秒 → 强杀
- **不得在 `{app}` 放置 `config.json`** —— `AppConfig` 会优先用它，而 `Init()` 无 try/catch，
  在 Program Files 中非管理员写入会**导致应用崩溃**
- 默认只勾选开机启动；`/VERYSILENT` 下因 `skipifsilent` 不会拉起 G-Helper
- 测试安装/卸载前**先删干净 `C:\Program Files\G-Helper`** —— 目录已存在时 Inno 不负责删除它，
  会造成误判

### 配置位置

| 位置 | 用途 |
|---|---|
| `{app}\config.json` | 应用**从不创建**，仅在已存在时选用（portable 模式） |
| `%APPDATA%\GHelper\config.json` | 交互用户的真实配置 |
| `C:\ProgramData\GHelper\config.json` | SYSTEM 的 `charge` 任务读取；仅由 `Timer_Elapsed` 同步 |

### CLI（供安装器调用）

```
GHelper.exe --disable-services [--ac]   # 需管理员；--ac 额外覆盖 Armoury Crate 服务
GHelper.exe --install-startup           # 注册计划任务（主任务 + GHelperCharge）
GHelper.exe --uninstall-startup         # 移除两者
GHelper.exe --enable-services           # 恢复服务
```

安装器自身以管理员运行（`[Run]` 天然提权），**不会弹 UAC**。

计划任务实际有三个名字（`Startup.cs` 里拼接，源码中搜不到字面量）：

| 任务名 | 说明 |
|---|---|
| `GHelper_<SID>` | 主任务，按用户 SID 区分，多用户共存 |
| `GHelper` | 旧版遗留任务名，仅在迁移时删除 |
| `GHelperCharge` | 电量上限任务，由 `Schedule()` 顺带注册 |

所以验证安装/卸载结果要用通配符 `Get-ScheduledTask -TaskName 'GHelper*'`，
按精确名 `GHelper` 查会漏掉当前真正生效的任务。

### workflow 陷阱

- **`secrets` 上下文不能用于 step 级 `if`** —— 必须经 job 级 `env` 中转，否则整个文件校验失败
  （症状：run 无 job、瞬时失败、`name` 回退成文件路径）
- 发布 workflow **不要**加 `paths-ignore`：tag 指向 commit 而非文件 diff，可能静默吞掉发布
- CI workflow 用 `paths-ignore`（非白名单），这样将来新增构建输入不会漏触发
- YAML 语法校验（`yaml` npm 包等）**查不出** GitHub 表达式上下文错误，只能靠实跑

### Agent 不执行的操作

不执行：`git push`、`gh release *`、`gh pr *`、`gh workflow run`、GitHub 仓库设置变更。
执行前先跑校验并汇报，由维护者动手。

## 环境

- .NET SDK 10.0.401（本机已装）；`app/global.json` 内容为 `{` + `}`（不含 `sdk` 字段），SDK 版本未固定
- Inno Setup 7.1.0 **per-user** 安装于 `%LOCALAPPDATA%\Programs\Inno Setup 7\`
- 本机**无** choco；CI 侧 `windows-2022` runner 自带，但 CI 不用 choco
  （choco 只有 Inno Setup 6.7.1，没有 7.x 包，CI 改为从 GitHub Releases 拉固定版本）
- PowerShell 对 WinExe 不等待：用 `Start-Process -Wait -PassThru -NoNewWindow`
- PowerShell 会把 git 的 stderr 当错误：`git push` 成功也返回 exit 1，以 `git ls-remote` 为准

## 参考文件

| 文件 | 内容 |
|---|---|
| `docs/installer/git-manual.md` | Git 规则的权威来源（分支、tag、合并窗口、门禁） |
| `docs/installer/pitfalls.md` | **临时工作笔记，不提交**；踩过的坑与实测结论 |
| `AGENTS.md` | 本文件 |