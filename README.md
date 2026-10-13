# oci-arm-kit

甲骨文云（OCI）Always Free ARM 实例自动创建工具包。

目标规格为 `VM.Standard.A1.Flex`（2 OCPU + 12GB）。Always Free 的 ARM 容量长期不足，手动创建通常失败。脚本按固定间隔循环调用官方 API 请求创建；当前可用性域无容量时轮换到下一个。创建成功后脚本退出，不重复创建。

![Shell](https://img.shields.io/badge/Shell-bash-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian%20%7C%20Git%20Bash-blue)
![Self--test](https://img.shields.io/badge/self--test-8%2F8%20passing-brightgreen)
![License](https://img.shields.io/badge/License-MIT-green)

## 📖 目录

- [📦 组件](#-组件)
- [🔄 工作流程](#-工作流程)
- [📝 前置条件](#-前置条件)
- [🚀 快速开始](#-快速开始)
- [⚙️ 脚本参考](#-脚本参考)
- [🧠 核心算法](#-核心算法)
- [🩺 离线自检](#-离线自检)
- [❓ 常见问题](#-常见问题)
- [🔒 安全与约定](#-安全与约定)
- [🗂 版本](#-版本)
- [📄 许可](#-许可)

## 📦 组件

| 文件 | 运行位置 | 作用 |
|---|---|---|
| `oci-arm-catcher.sh` | 服务器或任意 Linux | **核心脚本**。循环创建实例，分类错误，轮换可用性域，成功后退出。可独立运行。 |
| `oci-arm-auto.sh` | 服务器（Ubuntu / Debian，可用 E2.Micro 充当） | **部署器**。安装 OCI CLI、生成密钥、引导添加公钥、验证认证、查询子网与镜像、生成配置文件、启动抢购。 |
| `oci-info-from-tabbit.sh` | 本机（Windows + Git Bash） | **提取器**。从已登录的 Tabbit 浏览器读取租户 OCID、用户 OCID、区域代码与指纹。 |
| `tests/catcher-selftest.sh` | 任意（需 python3） | **离线自检**。用桩命令验证核心脚本，不联网。 |
| `GUIDE.md` | — | **使用指南**。含各项信息的获取位置、格式、验证方法与对照检查清单。 |

下文使用三个简称：核心脚本、部署器、提取器。

## 🔄 工作流程

```mermaid
flowchart LR
  subgraph local["本机（可选）"]
    B["Tabbit 浏览器<br/>已登录控制台"]
    I["提取器"]
    E["oci-info.env<br/>OCID 与区域，非机密"]
    B --> I --> E
  end
  subgraph server["服务器"]
    A["部署器"]
    C["核心脚本 + .env"]
    A --> C
  end
  O[("OCI API")]
  E -. "手工复制或 Agent 传递" .-> A
  C -->|"循环调用 instance launch"| O
```

本机准备接入信息，服务器执行抢购。

## 📝 前置条件

| 条件 | 说明 |
|---|---|
| Oracle Cloud 账号 | 没有账号时先读 [GUIDE.md](GUIDE.md) 第 10 章。Home Region 选定后不可更改，Always Free 实例只能在 Home Region 创建。 |
| 常开的 Linux 服务器 | Ubuntu 或 Debian。Always Free E2.Micro（1/8 OCPU + 1GB）可作引导机，每账号最多 2 台。抢购需长期运行，不宜使用个人电脑。 |
| 网络访问 | 服务器需能访问 OCI API（`cloud.oracle.com`）。 |

额度：A1 实例集上限为 2 OCPU + 12GB（2026-06 起）。月度用量池以控制台横幅为准。

## 🚀 快速开始

| 情况 | 方式 | 入口 |
|---|---|---|
| 使用 AI Agent（Claude Code、ZCode 等） | 方式 C | [Agent 提示词模板](#方式-cagent-提示词调用) |
| 本机装有 Tabbit 并已登录控制台 | 方式 A | 全自动流水线（GUIDE 4.3） |
| 不使用 Tabbit | 方式 B | 交互式部署（GUIDE 4.2） |
| 逐条命令手工执行 | 方式 D | GUIDE 4.1 |

获取工具包：`git clone https://github.com/Circumsized/oci-arm-kit.git`；无 git 时从仓库页 Code → Download ZIP 下载。

### 方式 A：全自动（本机有 Tabbit）

```bash
# 1. 本机读取接入信息，产出 oci-info.env
bash oci-info-from-tabbit.sh -o oci-info.env

# 2. 上传到服务器（<KEY>：SSH 私钥路径；<SERVER>：服务器地址）
scp -i <KEY> oci-arm-auto.sh oci-arm-catcher.sh oci-info.env ubuntu@<SERVER>:~/

# 3. 部署（两个脚本须在同一目录）
ssh -t -i <KEY> ubuntu@<SERVER> "source ~/oci-info.env && bash ~/oci-arm-auto.sh"
```

部署器中途输出公钥。粘贴到控制台 API 密钥页，返回终端按回车。

### 方式 B：交互式（不使用 Tabbit）

```bash
scp -i <KEY> oci-arm-auto.sh oci-arm-catcher.sh ubuntu@<SERVER>:~/
ssh -t -i <KEY> ubuntu@<SERVER> "bash ~/oci-arm-auto.sh"
```

部署过程需三次输入：公钥粘贴确认、回车、三个标识（用户 OCID、租户 OCID、区域代码）。每步均标注控制台位置。部署器完成后自动在后台启动抢购。

确认进程：

```bash
pgrep -af oci-arm-catcher
```

### 方式 C：Agent 提示词调用

模板补全后发送给 AI Agent。完整模板见 [GUIDE.md](GUIDE.md) 第 5 章。

```text
帮我部署甲骨文 ARM 抢购工具包，信息如下：
- 服务器：ubuntu@<SERVER>，SSH 私钥：<本机私钥路径>
- 工具包文件：本机 oci-arm-auto.sh 与 oci-arm-catcher.sh（同目录）
- OCI_USER_OCID=<用户OCID>   OCI_TENANCY_OCID=<租户OCID>   OCI_REGION=<区域代码>
- API 密钥：请让部署器在服务器生成新密钥，并把公钥给我，我去控制台粘贴
要求：先 scp 上传两个脚本到服务器 → 用 --no-start 部署并回报结果 →
我粘贴公钥后完成后台启动 → 告诉我查看日志的命令。
```

## ⚙️ 脚本参考

### 核心脚本（oci-arm-catcher.sh）

```text
用法: ./oci-arm-catcher.sh [选项]
  --stack-id OCID   启用 Stack 模式，直接执行已创建的 Resource Manager Stack
  --env-file FILE   指定配置文件。默认依次查找 ./arm.env、脚本同目录/arm.env、
                    ./.env、脚本同目录/.env。
  --name NAME       实例显示名。默认 arm-free-1。
  --ocpus N         实例 OCPU 数。默认 2。
  --memory N        实例内存 GB。默认 12。
  --interval SEC    重试间隔秒数。默认 300。低于 300 可能触发限流。
  --once            只尝试一次。成功 0 / 容量不足 3 / 其他错误 1。适合 Agent 巡检。
  -h, --help        显示帮助。   -V, --version  显示版本号。
```

| 配置键（.env 与环境变量同名） | 模式 | 必填 | 说明 |
|---|---|---|---|
| `STACK_OCID` 或 `STACK_ID` | Stack 模式 | 是 | Resource Manager Stack OCID（传入则自动切换为 Stack 模式） |
| `COMPARTMENT_ID` | Direct 模式 | 是 | 租户 OCID（根区间）或子区间 OCID |
| `SSH_KEY_FILE` | Direct 模式 | 是 | 实例登录公钥路径（`.pub` 文件） |
| `SUBNET_ID` | Direct 模式 | 是 | 公有子网 OCID |
| `IMAGE_ID` | Direct 模式 | 是 | aarch64 镜像 OCID |
| `AVAILABILITY_DOMAIN(S)` | Direct 模式 | 是 | 单个，或逗号分隔多个。多个时自动轮换 |
| `DISPLAY_NAME` / `OCPUS` / `MEMORY_GB` / `RETRY_INTERVAL` | 通用 | 否 | 默认 `arm-free-1` / `2` / `12` / `300` |

退出码：`0` 成功，`1` 配置错误或不可重试的错误，`2` 参数错误，`3` `--once` 模式下容量不足。

### 部署器（oci-arm-auto.sh）

```text
用法: bash oci-arm-auto.sh [选项]
  --key FILE            复用已有 API 私钥。指纹自动计算。
  --name NAME           实例显示名。
  --ocpus N             实例 OCPU 数。      --memory N   实例内存 GB。
  --interval SEC        重试间隔秒数。
  --subnet OCID         直接指定子网，跳过查询。   --image OCID  直接指定镜像。
  --os NAME             镜像系统。默认 Canonical Ubuntu。可传 "Oracle Linux"。
  --noninteractive      非交互模式。全部输入来自环境变量。
  --no-start            只部署，不启动抢购。
  -h, --help            显示帮助。   -V, --version  显示版本号。
```

环境变量：`OCI_USER_OCID`、`OCI_TENANCY_OCID`、`OCI_REGION`、`OCI_PUBLIC_KEY_ADDED=yes`、
`OCI_SUBNET_ID`、`OCI_IMAGE_ID`、`OCI_OS`、`OCI_ARM_CATCHER_SRC`。

部署器将核心脚本安装到 `~/oci-arm-catcher/` 并在同目录生成 `.env`，因此两个脚本必须位于同一目录。

### 提取器（oci-info-from-tabbit.sh）

```text
用法: bash oci-info-from-tabbit.sh [-o FILE] [-q]
  -o, --write-env FILE   结果写入 FILE。权限 600。文件含 export，可直接 source。
  -q, --quiet            只输出结果。
  -h, --help / -V, --version
```

## 🧠 核心算法

```mermaid
flowchart TD
  S["第 N 次尝试<br/>当前可用性域"] --> L["调用 instance launch<br/>参数 --no-retry"]
  L -->|成功| OK["打印实例 OCID<br/>退出码 0"]
  L -->|失败| C{"错误分类"}
  C -->|"STOP 类<br/>配额、权限、参数"| STOP["立即停止，退出码 1<br/>打印原因"]
  C -->|"RETRY 类<br/>容量不足、瞬时故障"| R{"--once 模式？"}
  R -->|是| E3["退出码 3"]
  R -->|否| W["等待 RETRY_INTERVAL<br/>轮换下一个可用性域"] --> S
```

| 分类 | 匹配的错误 | 行为 |
|---|---|---|
| STOP | `LimitExceeded`、`NotAuthorizedOrNotFound`、`NotAuthenticated`、`InvalidParameter`、`CannotParseRequest`、`NotAllowed`、未知错误 | 立即停止。重试无意义。打印原因，提示检查配额或配置。 |
| RETRY | `Out of host capacity`、`InternalError`、`TooManyRequests`、`ServiceUnavailable`、`timed out`、`RequestException` 等 | 等待 `RETRY_INTERVAL` 秒后重试。多个可用性域时依次轮换。 |

设计要点：

1. `--no-retry` 关闭 OCI CLI 的内层重试，每次尝试耗时可控、重试间隔准确。
2. 创建成功后脚本自动退出；重跑前先确认是否已创建实例。
3. 2026-06 起 A1 额度为 2 OCPU + 12GB，超配返回 `LimitExceeded`，命中 STOP 分类。

## 🩺 离线自检

自检不联网、不消耗配额，用桩命令模拟真实错误流：

```bash
bash tests/catcher-selftest.sh

# == 用例 1：容量不足 → 轮换可用性域 → 成功    ✓✓✓
# == 用例 2：LimitExceeded（配额类）→ 立即停止  ✓
# == 用例 3：--once 容量不足 → 退出码 3         ✓
# == 用例 4：缺少必填配置 → 退出码 1            ✓
# == 用例 5：Stack Apply 模式 → 成功            ✓✓
# 全部通过：8 项检查
```

## ❓ 常见问题

**1. 为什么不从浏览器读取 API 私钥？**

控制台只在生成密钥时提供一次私钥下载，之后不再显示，丢失后只能删除密钥重新生成。本工具包的方案是私钥在服务器本地生成，不经过浏览器；公钥可重复粘贴。

**2. 认证失败（`oci iam region list` 报错）怎么办？**

依次检查：公钥是否整段粘贴、是否点击"添加"、脚本输出的指纹与控制台列表是否一致。部署器支持失败后按回车重试。

**3. 提取器报"未找到控制台标签页"怎么办？**

先在 Tabbit 登录 `cloud.oracle.com`。Oracle 改版后菜单文案可能变化，按报错信息调整提取器中的中文关键词。

**4. 日志出现 `LimitExceeded` 后工具停止，是故障吗？**

不是。配额已满时重试无效，核心脚本停止并输出原因。

**5. 创建成功后做什么？**

在控制台 Compute → Instances 确认实例并记录公网 IP，从执行抢购的服务器登录：

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<实例公网IP>   # Ubuntu 镜像；Oracle Linux 为 opc
```

私钥位于该服务器的 `~/.ssh/id_ed25519`。抢购进程在创建成功后自动退出，用 `pgrep -af oci-arm-catcher` 确认。

**6. 如何修改配置并重跑？**

修改 `~/oci-arm-catcher/.env` 后重跑核心脚本；或重新运行部署器。部署器可重复执行，不覆盖已有密钥。

**7. Resource Manager Stack 是什么？**

Resource Manager 的 Stack 将实例配置保存为模板，可反复执行。执行命令：

```bash
oci resource-manager job create-apply-job \
  --stack-id "$STACK_OCID" \
  --execution-plan-strategy AUTO_APPROVED
```

核心脚本已内置该模式。若控制台（Developer Services → Resource Manager → Stacks）中已有 A1 Flex Stack：

```bash
./oci-arm-catcher.sh --stack-id "ocid1.ormstack.oc1..."
```

或将 `STACK_OCID=ocid1.ormstack.oc1...` 写入 `.env`。作业等待、失败退避（默认 300 秒）与成功退出由脚本处理。

模式选择：Direct Launch（默认）调用 Compute API，可在多个可用性域间轮换重试；Stack Apply 仅需 `STACK_OCID`，子网、镜像、SSH 路径均来自 Stack 模板。

**8. 服务器会被甲骨文回收吗？**

会。Oracle 对 Always Free 实例有闲置回收政策，低利用率达到阈值时可能被判定闲置并回收。阈值以官方政策为准。免费实例不适合承载重要业务，数据需定期备份。

## 🔒 安全与约定

API 私钥仅存于服务器 `~/.oci/oci_api_key.pem`（权限 600），脚本不向外发送数据。源码不含真实凭据，只有 `ocid1.user.*` 等格式校验模式；`.gitignore` 排除运行期生成的 `.env` 与密钥文件。

脚本仅使用相对路径与 `$HOME`、`$LOCALAPPDATA` 等标准环境变量。文档占位符：`<KEY>`、`<SERVER>`、`<实例公网IP>`。

`.env` 与 `oci-info.env` 中的 OCID 非机密，但整份文件建议按凭据管理：权限 600，不入库。

## 🗂 版本

| 版本 | 日期 | 说明 |
|---|---|---|
| v3.1.0 | 2026-10-13 | 文档补全：GUIDE 新增注册导读章（Home Region、失败排查、E2.Micro 引导机）；新增 401 逐字段检查表、界面版本自检表、进程检查命令、防扣费清单、闲置回收提示；README 新增前置条件与 Stack 替代方案 FAQ；术语表扩充。 |
| v3.0.0 | 2026-10-13 | 核心算法独立成核心脚本。新增离线自检。部署器改为同目录安装，取消 git 依赖。文档重构。 |
| v2.0.0 | 2026-10-13 | 统一帮助、选项与退出码。新增非交互模式、`--no-start`、`--subnet`、`--image`、`--os`。 |
| v1.0.0 | 2026-10-13 | 初版。 |

## 📄 许可

[MIT](LICENSE)