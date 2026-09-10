# 非阻塞项目检测与 Spring 资源发现实施计划

> 按任务顺序实施，每阶段完成对应验证后再进入下一阶段。

**Goal:** 在用户目录打开 `.bashrc` 时不启动递归项目扫描，并让真实项目中的 Spring 资源发现可取消、可复用且不阻塞编辑。

**Architecture:** 保留以 cwd 为项目上下文的现有约定，先通过固定路径标志完成轻量候选判断，再在明确的项目边界内异步发现资源。发现结果由框架识别与 parser 共享，激活入口统一管理完成、失败、取消和过期结果。

**Tech Stack:** Lua、Neovim API、libuv、现有 ripgrep/Git 发现策略；使用 Neovim headless 与 gitignored fixtures 验证，不新增测试框架或生产依赖。

---

## 已确认问题

- `init.lua:398–429`：auto 启动检查不区分文件类型。
- `framework.lua:358–359`：布尔项目判断调用完整 `spring_messages.discover()`。
- `spring_messages.lua:50–95`：同步 systemlist 或无工作量上限的 Lua 递归寻找 POM。
- `spring_messages.lua:222`：递归 glob 同步扫描模块资源目录。
- `spring_messages.lua:112–122`：发现缓存下一次 scheduled callback 即清空。
- `framework.detect()` 与 `parser.load_translations()` 再次进入发现逻辑。
- manual 提示也触发项目检测；generic provider 未传入启动检测。
- 激活中断可能跳过 `_activation_pending` 清理。

## 范围与兼容性决策

1. 首轮保持 cwd 语义，不引入多 buffer、多项目常驻状态。所有检测使用一次捕获并规范化的 root，后续不重新读取 cwd。
2. 自动 Spring 发现要求 cwd 根目录存在 `pom.xml`。`.git` 本身不能证明是 Maven 项目，不作为自动 Spring 扫描许可。
3. 不再从没有根 POM 的项目集合目录自动寻找所有子项目。此类用户可进入 Maven 根目录，或在明确的工作区 cwd 中显式使用 `provider = 'spring_messages'`。显式 provider 仍使用有预算的异步扫描。
4. 用户主目录和文件系统根目录不允许默认 Spring 深度扫描；显式 provider 才表达扫描意图。普通 i18n 固定标志判断仍保留。
5. 不用新增文件类型限制改变 auto 的语义；lazy 继续由支持的文件类型触发。
6. 首轮保留项目边界内现有 rg/Git/Lua 模块发现策略，不解析 Maven XML 的 `<modules>`。正确处理 profile、属性和外部模块会扩大范围；模块图优化作为后续工作。
7. 激活改为异步完成涉及公共 API 时，先核实 `M.activate()` 当前返回值及内部/文档调用方。保留返回值原有含义，增加可选完成回调前需确认接口兼容性，不将“请求已提交”伪装成“已激活”。

## Task 1：建立基线与受控复现

**文件：** 新建 gitignored `tests/manual/discovery_regression.lua`，必要 fixture 放在 `tests/fixtures/discovery/`。

1. 核查 `.gitignore`、最低 Neovim 版本、`M.activate/deactivate/setup`、parser reload 和 watcher 完整调用方；记录公共返回值约定。
2. 创建模拟 home：根目录 `.bashrc`，深层放一个最小 Spring Maven 项目，不遍历真实 home。
3. 包装 `vim.fn.systemlist`、`vim.fn.glob` 和目录扫描入口计数，执行启动检测并记录扫描范围；包装在验证结束后恢复。
4. 为无 POM、普通 Maven、Spring 单模块、Spring 多模块准备小型 fixture。
5. 记录 `vim.loop.hrtime()` 总耗时与短周期 timer 心跳间隔；延迟采用现有 timer，同步忙循环不能作为异步测试替身。

**验证命令：**

```sh
nvim --headless -u NONE --cmd "set rtp^=." -l tests/manual/discovery_regression.lua
```

脚本自行切换 fixture cwd，以断言失败退出非零状态。最低支持版本若不支持 `-l`，改用 `+"lua dofile('tests/manual/discovery_regression.lua')"` 并在脚本内退出。

**通过标准：** 当前缺陷可在小 fixture 上用“发生了不应发生的递归扫描”证明，而不依赖制造长时间卡顿。

## Task 2 / P0：限定根目录，移除启动深度扫描

**修改：** `lua/i18n/framework.lua`、`lua/i18n/spring_messages.lua`、`lua/i18n/init.lua`。

1. 为内部检测传递统一上下文：规范化 root、实际 provider、resource_root、自动或显式触发来源。
2. 将“是否允许 Spring 发现”的固定路径判断独立出来，供框架检测、parser 和所有激活入口复用。
3. auto/generic 在无根 POM 时不调用任何 Spring 递归扫描；generic 始终跳过 Spring provider。
4. 区分候选与已确认：根 POM 仅表示 Maven 候选，不能直接判定 Spring、有翻译资源或完成激活。
5. `framework.is_i18n_project()` 保持布尔接口，不把候选当肯定结果；内部启动流程使用单独的候选探测结果驱动后续确认。若其现有 Spring 确认语义无法同步保留，明确记录内部 API 调整并改完全部调用方。
6. 在 `discover` 自身加边界入口保护，避免 parser 或调试命令绕过启动检查。
7. manual 提示仅基于廉价已确认信息或缓存，不因提示执行深度发现。
8. 初步为同步过渡路径补充异常清理，确保 pending 不残留。

**通过标准：** 模拟 home 下 auto 打开 sh、JSON、Java 都没有 Spring 子进程或递归扫描；generic 不扫描 Spring；真实 Maven 根仍可进入受控发现。

## Task 3 / P1：建立统一异步发现生命周期

**修改：** `lua/i18n/spring_messages.lua`；必要时创建 `lua/i18n/discovery.lua` 专门承载共享任务生命周期。

1. 定义内部回调协议：结果包含 descriptors/locales；状态区分成功（含成功为空）、错误、取消、预算耗尽。每次请求只完成一次。
2. 固定 root 和配置快照，返回取消句柄；完成回调统一在 UI 安全上下文调用。
3. 将 rg/Git systemlist 改为项目最低 Neovim 版本支持的异步进程 API，不调用阻塞式 wait。
4. 保留 rg 无匹配为成功空结果、执行失败才回退的语义；Git 失败再进入 Lua 回退。
5. 子进程设置超时与输出预算，必要时增量接收输出，避免先无限收集再检查大小。
6. Lua 回退使用异步目录读取和分批处理，限制并发与每批条目数；不使用一个 scheduled callback 包裹整棵同步递归。
7. 取消或超时终止子进程、关闭 timer/句柄、清空队列，并阻止新工作启动。

**通过标准：** 人为延迟发现完成期间 timer 心跳持续；错误/取消只回调一次；无 rg、无 Git、非 Git 根路径均有可工作的异步回退。

## Task 4 / P1：替换资源 glob，限制扫描工作量

**修改：** `lua/i18n/spring_messages.lua` 的 `bundle_descriptors`、`inferred_bundle_descriptors`、POM/config 读取与 Spring 判断。

1. 默认或配置 basename 使用定向目录枚举；推断扫描仅进入已确认模块的 resource_root。
2. 用异步扫描替换 `**/messages*.properties`；遍历时排除 `.git`、`node_modules`、`target` 等现有非源目录。
3. 明确 symlink 策略：默认不沿目录链接递归；候选路径 realpath 后验证边界，避免循环或逃出项目。
4. POM 和配置文件异步读取或按批次处理，并限制单文件读取大小；避免大 POM 又形成同步长任务。
5. 保留 basename 优先级、locale 解析、默认 bundle 和模块隔离语义；推断 basename 排序后生成稳定 priority。
6. 引入内部预算初值：并发目录读取 4、每批处理 128 条、单批目标约 4ms、任务超时 5s、目录上限 20000、候选文件上限 100000。它们是待基准校准的实现初值，不是性能保证；外部进程另设输出字节限制。
7. 达到预算返回明确的 incomplete 状态，不静默提交部分结果，不缓存为无资源。自动路径至多通知一次；手动命令提供具体失败原因。

**通过标准：** 嵌套 messages、显式 basename、中文 locale、空资源目录仍正确；超大树、权限失败和符号链接不导致无限任务。

## Task 5 / P1：接通激活、加载、reload 和命令

**修改：** `lua/i18n/init.lua`、`lua/i18n/framework.lua`、`lua/i18n/parser.lua`；审查 `lua/i18n/usages.lua` 的现有调用顺序。

1. 框架完整识别接收已有发现结果，不再次发现；移除 `framework.detect()` 的重复 Spring fallback 扫描。
2. parser 接收同一份 descriptors/locales，不在 `load_translations()` 内再次同步发现。
3. 将激活明确分成“获取上下文 → 轻量探测 → 异步确认 → 应用建议 → 加载 → 初始化 UI/usage → 标记完成”。
4. 如大批 `.properties` 同步读取/解析仍阻塞，将加载按文件和工作量分批；使用临时结果，成功后统一发布索引，不暴露半加载状态。
5. 增加私有完成后执行入口，迁移 ShowTranslations、DefinitionNextLocale、AddKey、KeyUsages 等“activate 后立即使用数据”的命令。
6. `I18nReload` 等待单次加载完成后再 refresh，取消当前重复 load；reload 失败保留已有完整翻译结果。
7. 每次任务使用递增 generation；禁用、重新 setup、目录变化、reload 使旧 generation 失效。旧回调不能清理或覆盖新任务状态。
8. `DirChanged` 取消在途任务，依据原激活模式决定是否重新检查；不扩展成多项目常驻功能。
9. 成功、失败、取消均通过统一 finish 清理 pending。仅成功设置 `_activated` 并显示 Activated。
10. 同步审查 generic 自动目录发现是否在本流程中从 home 被启动；维持相同边界约束，真实项目的进一步通用扫描优化按实测决定。

**通过标准：** 开启后立即执行命令可正确等待；加载中 disable 不会复活；A→B 切 cwd 后 A 的结果不会写入 B；reload 不重复发现和加载。

## Task 6 / P2：缓存、并发合并与失效

**修改：** `lua/i18n/spring_messages.lua`、`lua/i18n/framework.lua`、`lua/i18n/init.lua`、`lua/i18n/parser.lua`。

1. 删除下一次 schedule 清空所有缓存的实现。
2. 以 root、provider、require_spring、resource_root 和其他实际影响发现的选项构造缓存键。
3. 同键请求合并为一个底层发现任务；不同等待者保留各自回调和取消状态，最后一个等待者取消才停止共享任务。
4. 只缓存完整成功结果，包括成功为空；错误、取消、预算耗尽不作负缓存。
5. 使用有界缓存：初值正缓存 30s、负缓存 5s、最多 16 个 root/config 条目；使用单调时钟，不增加持久化文件。
6. reload 强制失效当前键；POM、application/bootstrap 配置、messages 文件的相关写入使当前项目结果失效。新增/删除 bundle 的外部变化由 TTL 或 reload 发现，避免引入递归 watcher。
7. 对齐 framework 缓存失效，避免 Spring 已失效而框架仍命中旧结果。

**通过标准：** 同项目多事件仅执行一次发现；TTL 后重试；修复错误后立即重试；新增 bundle 后 reload 生效。

## Task 7：文档与最终验证

**修改：** `README.md`、`doc/i18n.nvim.txt`；必要时更新 `doc/tags`，不新增命令或默认快捷键。

1. 更新 auto/lazy/manual/eager、provider 和项目边界说明。
2. 明确根 POM 自动检测规则、无聚合根的显式使用方式和加载中命令行为。
3. 描述取消、reload 失效、预算失败反馈及新增 DirChanged/写入 autocmd 的作用。
4. 完成以下矩阵，记录扫描调用计数、激活状态、资源结果和心跳最大延迟。

| 场景 | 预期 |
| --- | --- |
| 模拟 home 打开 `.bashrc` / JSON / Java，auto | 无 Spring 深度扫描 |
| generic provider，含 Spring 子项目 | 无 Spring provider 扫描 |
| manual 启动 | 不为提示启动深度扫描 |
| 普通 Maven，无 Spring | 不误判 Spring |
| Spring 单模块与聚合多模块 | locales、basename 和模块隔离正确 |
| 无根 POM 的项目集合目录 | auto 不扫描；显式 provider 可受控发现 |
| rg 缺失、Git 失败、Lua 回退 | 结果等价，UI 可响应 |
| 大资源树、链接循环、权限失败 | 有界完成或明确错误 |
| 慢发现过程中移动、输入 | 心跳持续，编辑可用 |
| 加载中 disable、reload、切 cwd | 旧结果不提交 |
| 并发请求、负缓存到期、新增 bundle | 合并与失效正确 |
| Vue/React generic fixture | 现有翻译和导航无回归 |

5. 性能目标：受控本地 fixture 上普通非项目检测目标 <10ms，扫描期间心跳最大额外延迟目标 <50ms。记录机器环境和多次结果；以“无递归调用”和“异步期间持续响应”为确定性门槛，不将墙钟目标当跨机器保证。
6. 执行 headless 验证，再交互执行 `:I18nEnable`、`:I18nDisable`、`:I18nReload`、`:I18nStatus`、`:I18nDetectFramework`、`:I18nAddKey` 与定义跳转。
7. 执行文档标签与差异检查：

```sh
nvim --headless -u NONE "+helptags doc" +qa
git diff --check
git status --short
```

## 交付顺序

- **里程碑 A（Task 1–2）：** home 不再触发误扫描，边界规则有验证。
- **里程碑 B（Task 3–5）：** 真实项目发现/相关加载异步化，命令与取消生命周期完整。
- **里程碑 C（Task 6–7）：** 缓存有效、文档同步、回归矩阵完成。

实际编码前先检查工作区变化；不添加新测试框架。不在本计划阶段修改运行时代码，提交操作由用户另行授权。
