# G-Helper-Installer Git 管理手册

> 本文档约束本 fork 的全部 Git 操作。**与本文档冲突的操作一律视为错误。**
>
> 适用范围：`installer-release` 分支上的开发、上游同步、打 tag 与发布。
> `main` 分支不在开发范围内，仅作为上游镜像。

---

## 1. 仓库角色

| 分支 | 角色 | 允许的操作 |
|---|---|---|
| `main` | 上游 `seerge/g-helper` 的**纯净镜像** | 仅 `merge --ff-only upstream/main` 后 push；**禁止**在其上产生任何自有 commit、tag 或代码修改 |
| `installer-release` | **发布分支**（是否为 GitHub 默认分支均可，见 §9） | 全部 overlay 开发；所有 tag 从此分支产生 |

远端约定：

```
upstream → https://github.com/seerge/g-helper.git     （唯一的上游来源）
origin   → Nothing9495/G-Helper-Installer
```

---

## 2. 核心不变式

以下三条是硬约束，任何操作都不得破坏：

### 不变式 1 —— 合并窗口锚定

`installer-release` 上**任何**来自上游的 commit，都必须经由某个 merge commit 引入，且该 merge 的**第二父提交**是 `main` 上的一个**版本边界 commit**。

> 推论：不存在「上游 commit 被直接 cherry-pick」或「整体 merge 上游 main HEAD」的情况。

### 不变式 2 —— 禁止未打 tag 的上游提交

`main` 的 HEAD 通常**领先**于上游最新 tag（未发布的 commit）。这类 commit **永远不得**进入 `installer-release`。

以当前仓库为例：

```
main:              ○──○──● 900e6a51 "Version bump"  ← 上游 v0.286 边界，可合并
                      └──○ 480b07ec "Crowdin updates"  ← 未打 tag，禁止合并
```

### 不变式 3 —— 不获取上游 tag

**禁止**执行 `git fetch upstream --tags`、`git fetch --tags`，禁止建立 `refs/upstream-tags/*` 等任何上游 tag 镜像。

原因：本 fork 自行创建与上游同名的 tag（见 §4）。若同时引入上游 tag 对象，会产生同名不同物的 ref 冲突。

上游版本信息**只从 `main` 的提交历史推导**（见 §3）。

---

## 3. 上游版本边界发现

seerge 的发版约定：每个 release 对应一次提交信息为 `Version bump` 的 commit，且该 commit 正是修改 `AssemblyVersion` 的那次。

### 枚举所有版本边界

```powershell
git log main --format="%H" --grep="^Version bump$" | ForEach-Object {
    $sha   = $_
    $csproj = (git show "${sha}:app/GHelper.csproj") -join "`n"
    $ver    = ([regex]'<AssemblyVersion>([^<]+)</AssemblyVersion>').Match($csproj).Groups[1].Value
    "{0,-10} {1}" -f $ver, $sha.Substring(0, 8)
}
```

输出即完整的「版本号 → SHA」映射表。使用 `AssemblyVersion` 而非提交信息作为版本号来源，因此不依赖提交信息格式的稳定性。

示例输出：

```
0.286      900e6a51
0.285      4ba1a0ab
0.284      fe69a4da
```

### 判定待合并窗口

判据是**祖先关系**，无状态、不依赖任何 manifest 文件：

```bash
git log main --format=%H --grep="^Version bump$" | while read sha; do
  git merge-base --is-ancestor $sha HEAD \
    && echo "已合并: $sha" \
    || echo "待合并: $sha"
done
```

> 祖先关系判据不会因 manifest 丢失、提交被 revert、tag 被误删而失效。

---

## 4. Tag 策略

### 命名规则（不可违背）

```
v<版本号>      例：v0.286
```

版本号必须等于合并后 `app/GHelper.csproj` 中的 `AssemblyVersion`。

这不是风格偏好，是**硬性功能约束**：`app/AutoUpdate/AutoUpdateControl.cs` 中执行
`new Version(tag_name.Replace("v", ""))` 并与程序集版本比较。命名一旦偏离，
自动更新的版本比较会静默失效。

### 三条规则

1. **来源唯一** —— tag 只能从 `installer-release` 的 commit 创建。**禁止**在 `main` 或上游创建 tag。
2. **对象唯一** —— 本地仅 `refs/tags/vX.Y` 指向我们自己的 merge commit。
3. **天然对齐** —— tag 落在窗口边界上，版本号与上游严格对应。

### 创建方式

```bash
git tag -a v0.286 -m "G-Helper Installer v0.286 (upstream 900e6a51)"
git push origin v0.286        # 触发 build-installer.yml
```

> `main` 上**永远不产生 tag**。建议在 GitHub 上配置 Ruleset 禁止向 `main` 创建 tag。

---

## 5. 同步 SOP

每个发版周期执行一次。五个步骤**均不可省略**。

### ① 更新 `main` 镜像（唯一的 upstream 接触点）

```bash
git checkout main
git fetch upstream
git merge --ff-only upstream/main
git push origin main
```

> 必须是 `--ff-only`。任何情况下 `main` 都不产生自有 commit。
> 按需更新，不需要实时镜像。

### ② 发现待合并边界

```bash
git checkout installer-release
git log main --format=%H --grep="^Version bump$" | while read sha; do
  git merge-base --is-ancestor $sha HEAD || echo "待合并: $sha"
done
```

### ③ 逐窗口合并

```bash
git merge --no-ff --no-edit \
  -m "Merge upstream v0.287 (2ca868a0)" \
  2ca868a0
```

- `--no-ff` 强制显式 merge commit，保证 `git log --merges --grep="Merge upstream tag"` 是一份完整的**发布审计日志**。
- 冲突时：解决后 `git add` + `git commit`；或 `git merge --abort` 放弃重来。

### 跳过中间版本

若上游已到 v0.288 而本分支停在 v0.286，可**直接合并 v0.288 的边界 SHA** —— git 会把 v0.286..v0.288 一次性带入，中间边界自动成为祖先。

| 策略 | 命令 | 适用 |
|---|---|---|
| 逐个（推荐） | 依次 merge 各边界 SHA | 冲突可分别诊断 |
| 一次 | 直接 merge 最新边界 SHA | 跨度大且预期无冲突 |

### ④ 本地验证

```powershell
./installer/build.ps1 -Tag v0.288
```

与 CI 使用**同一脚本**，确保本地验证与发布产物同源。

### ⑤ 打 tag 并推送

```bash
git push origin installer-release
git tag -a v0.288 -m "G-Helper Installer v0.288 (upstream 2ca868a0)"
git push origin v0.288
```

---

## 6. overlay 改动清单与冲突预期

本 fork 对 `app/` 的全部改动集中在少数位置，用于把合并冲突面压到最小：

| 文件 | 改动性质 | 冲突风险 |
|---|---|---|
| `app/AutoUpdate/AutoUpdateControl.cs` | 单个方法体内的连续 hunk | 🟡 中 —— 上游若改动该方法内部 |
| `app/Program.cs` | L54 附近插入 2 行 | 🟡 低 —— 上游若改动 `Main` 开头 |
| `app/AppConfig.cs` | 文件末尾追加 5 行 | 🟢 极低 |
| `app/Helpers/Startup.cs` | 可选参数（追加式，向后兼容） | 🟢 极低 |
| `app/GHelper.csproj` | Target 的 Condition 追加条件 | 🟢 极低 |
| `app/Helpers/ServiceCli.cs` | 全新文件 | 🟢 无 |
| `installer/**` | 全新目录 | 🟢 无 |
| `.github/workflows/**` | 新增 + 删除上游文件 | 🟡 见 §7 |

### 冲突处理原则

- **我们的 overlay 优先** —— 这些改动是本 fork 的分发形态所必需。
- 合并提交信息统一为 `Merge upstream vX.Y (<sha>)`，便于回溯。
- 启用 `rerere`，重复出现的冲突只解一次：

```bash
git config rerere.enabled true
```

### 上游 workflow 被删除导致的冲突

上游 `build.yml` / `release.yml` 已在本分支删除（见 §7）。若上游修改了这两个文件，
合并会产生 **modify/delete 冲突**，解决方式：

```bash
git rm .github/workflows/build.yml .github/workflows/release.yml
git commit
```

---

## 7. Workflow 策略

### 文件布局（`installer-release` 分支）

| 文件 | 来源 | 说明 |
|---|---|---|
| `build-installer.yml` | 新增 | **发布**工作流，触发条件 `push: tags: ['v*']` |
| `build-installer-CI.yml` | 新增 | **验证**工作流，push/PR 到 `installer-release`；跑完整 `iscc`，只上传 Artifact，**绝不发布** |
| `codeql.yml` | 上游保留 | 每周 `schedule` 运行；扫描目标取决于默认分支，见下方说明 |
| `build.yml` | 已删除 | 其 `on.push.branches: [main]` 在本分支永不触发；删除以减少未来 modify/delete 冲突面 |
| `release.yml` | 已删除 | 依赖本 fork 不具备的 SignPath secret；每次发版必然失败 |

### GitHub Actions 事件的文件来源

排查触发问题前须明确：workflow 定义并非一律取自默认分支。

| 事件 | 读取来源 |
|---|---|
| `push` | 被推送的 ref |
| `pull_request` | PR 的 merge ref |
| `release` | **tag 所指向的 commit** |
| `workflow_dispatch` | UI 中选定的 ref |
| `schedule` | **默认分支**（唯一真正依赖默认分支的事件） |

> 由此推论：tag 必须打在 `installer-release` 上。若误打在 `main`，
> 将命中 `main` 上的上游 workflow 定义而行为异常。

### 默认分支不影响发版与开发

上表说明：除 `schedule` 外，**所有事件的 workflow 定义都来自被操作的 ref，
而非默认分支**。因此本 fork 的发版与开发链路**不依赖默认分支设置**：

- `build-installer.yml` 由 `push` tag 触发 → 定义随 tag 所在的 commit 走
- 上游 `release.yml` 被删除后不再触发 → 依据是 tag commit 上不存在该文件
- `build.yml` 的 `branches: [main]` 隔离 → 依据是 `push` 事件按 ref 匹配

### `codeql.yml` 的扫描目标（默认分支的唯一实际影响）

`schedule` 恒从默认分支读取，**且只扫描默认分支**：

| 默认分支 | 每周扫描对象 | 对 overlay 的覆盖 |
|---|---|---|
| `main` | 纯上游代码 | 新增的 `ServiceCli.cs` **无覆盖** |
| `installer-release` | 含 overlay 的完整代码 | overlay 纳入扫描 |

这是**唯一值得为切换默认分支而切换的理由**。发版行为本身在两种设置下完全一致。

### `codeql.yml` 的权限依赖

`codeql.yml` 需要 `security-events: write`。若仓库
*Settings → Actions → General → Workflow permissions* 保持默认的
*Read repository contents permission for `GITHUB_TOKEN`*，其 `analyze` 步骤会**每周失败一次**。
必须设为 **Read and write**。此权限需求与默认分支设置无关。

---

## 8. 发布流程与门禁

`build-installer.yml` 在发布前执行三重校验，任一失败即中止：

1. **版本一致** —— `tag == "v" + AssemblyVersion`
2. **位置正确** —— tag 所指 commit 位于 `installer-release`
3. **窗口完整性** —— `boundary..HEAD` 之间不得出现非 overlay 作者的 commit

第 3 项将不变式 2「不夹带未打 tag 的上游提交」从**流程约定**升级为**CI 强制门禁**，
违反时发布直接失败，而非依赖人工自觉。

### 产物

```
dist/v<版本>/GHelper-v<版本>-Setup.exe
dist/v<版本>/SHA256SUMS.txt
```

文件版本号由 tag 值直接驱动。仅发布安装程序，**不发布** portable zip 或独立 exe。

---

## 9. GitHub 仓库设置要求

### 必需项

| 设置项 | 值 | 原因 |
|---|---|---|
| Actions → Workflow permissions | **Read and write** | `codeql.yml` 需要 `security-events: write` |
| Ruleset → `main` | 禁止 push | 保证镜像纯净 |
| Ruleset → `main` | 禁止创建 tag | 保证 tag 只从 `installer-release` 产生 |
| Ruleset → `main` | 仅允许 fast-forward | 结构上杜绝镜像分叉 |

### 可选项：默认分支

**默认分支设置不影响发版与开发**（依据见 §7）。两种取值均可正常工作：

| 默认分支 | 优点 | 代价 |
|---|---|---|
| `main`（**推荐**） | 仓库首页展示纯净镜像；Pages 站点与上游完全一致，fork 专属文档不会被发布；无需修改上游 `_config.yml` | `codeql.yml` 每周扫描 `main`，overlay 无安全覆盖 |
| `installer-release` | `codeql.yml` 覆盖 overlay | 仓库首页展示发布分支；Pages 会渲染 `docs/installer/git-manual.md`（需在 `_config.yml` 加 `exclude` 才能避免，而那是修改上游文件） |

> 推荐保持 `main` 为默认分支。仅当希望 CodeQL 覆盖 overlay 时才切换 —— 那是纯仓库设置操作，无需改动任何代码。

---

## 10. 禁止事项清单

- ❌ 在 `main` 上 commit、tag 或修改任何文件
- ❌ `git fetch upstream --tags` 或 `git fetch --tags`
- ❌ 建立 `refs/upstream-tags/*` 或任何上游 tag 镜像
- ❌ 合并 `main` 的 HEAD（而非版本边界 SHA）
- ❌ cherry-pick 上游 commit
- ❌ 创建非 `v<数字>.<数字>` 格式的 tag
- ❌ 在 tag 名中添加 `-setup`、`-installer` 等后缀
- ❌ 从 `main` 创建 tag
- ❌ 在未通过 §8 三重门禁时发布

---

## 11. 当前状态

### 已完成

- [x] 确认 `installer-release` 从 v0.286 边界 `900e6a51` 创建（不含未打 tag 的 `480b07ec`）

### 待完成

- [ ] 添加 `upstream` remote
- [ ] `git config rerere.enabled true`
- [ ] `main` 配置 `--ff-only`
- [ ] 落地 `app/` overlay 代码改动（见 §6）
- [ ] 编写 `installer/build.ps1` 与 `installer/GHelper.iss`
- [ ] 编写 `build-installer.yml` / `build-installer-CI.yml`
- [ ] 删除上游 `build.yml` / `release.yml`
- [ ] 配置 GitHub 仓库设置（见 §9）
- [ ] 首次 `v0.286` 发布

---

## 附：命令速查

```bash
# 发现版本边界
git log main --format=%H --grep="^Version bump$"

# 判断某边界是否已合并
git merge-base --is-ancestor <sha> HEAD && echo "已合并" || echo "待合并"

# 合并一个窗口
git merge --no-ff --no-edit -m "Merge upstream v0.287 (2ca868a0)" <sha>

# 查看发布审计日志
git log --merges --grep="Merge upstream"

# 确认某 tag 未夹带上游未发布提交
git log --oneline main ^HEAD
```