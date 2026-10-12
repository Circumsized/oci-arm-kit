# oci-arm-kit 使用指南

本文档说明 oci-arm-kit 的全部使用方法。
文档包含四部分：每一项信息的获取位置与验证方法、三种使用路径、Agent 用法、排错手册。

全文使用占位符。尖括号内容需要替换为你的真实值。

两条规则先记住：

1. **OCID 与指纹不是机密**。可以复制，可以发送给 Agent。
2. **私钥是机密**。不要粘贴到聊天窗口，不要提交到代码仓库。

## 📚 目录

1. [前置知识](#1--前置知识)
2. [信息总表与对照检查清单](#2--信息总表与对照检查清单)
3. [逐项获取详解](#3--逐项获取详解)
4. [三种使用路径](#4--三种使用路径)
5. [Agent 使用指南](#5--agent-使用指南)
6. [运行与运维](#6--运行与运维)
7. [排错手册](#7--排错手册)
8. [安全须知](#8--安全须知)
9. [附录：命令速查](#9--附录命令速查)

## 1. 📖 前置知识

术语表。全文使用表中名称，不再使用同义词。

| 术语 | 说明 |
|---|---|
| Always Free | 甲骨文云永久免费额度。ARM 规格为 `VM.Standard.A1.Flex`。2026-06 起，全部 A1 实例合计上限 2 OCPU + 12GB。超配请求返回 `LimitExceeded`。 |
| 区域代码 | 形如 `us-phoenix-1`。控制台右上角显示的是区域显示名，例如 `US West (Phoenix)`。脚本使用区域代码。对应关系见 3.3。 |
| 可用性域（AD） | 区域内的物理隔离机房分组，形如 `XXXX:PHX-AD-1`。ARM 容量按 AD 独立计算。一个 AD 容量不足时，另一个 AD 可能仍有容量。核心脚本轮换 AD 重试。 |
| 容错域（FD） | AD 内的机架分组。系统自动分配。对单台实例无影响。不需要配置。 |
| Out of host capacity | 当前 AD 没有 ARM 空闲容量。该错误可以重试。核心脚本等待后继续尝试。 |

## 2. 📋 信息总表与对照检查清单

### 2.1 信息总表

| 编号 | 信息 | 格式示例（占位符） | 来源 | 用途 |
|---|---|---|---|---|
| 1 | 租户 OCID | `ocid1.tenancy.oc1..aaaa…` | 控制台租户详细信息页 | 配置键 `COMPARTMENT_ID` |
| 2 | 用户 OCID | `ocid1.user.oc1..aaaa…` | 控制台用户设置页 | OCI CLI 配置 |
| 3 | 区域代码 | `us-phoenix-1` | 控制台区域菜单或页面 URL | OCI CLI 配置 |
| 4 | API 密钥对与指纹 | 私钥 `*.pem`、公钥 `*-public.pem`、指纹 `xx:xx:…` | 控制台 API 密钥页，或在服务器生成 | 脚本以你的身份调用 API |
| 5 | 可用性域 | `XXXX:PHX-AD-1` | CLI 查询 | 轮换重试的位置 |
| 6 | 子网 OCID | `ocid1.subnet.oc1…` | CLI 查询 | 实例接入的网络 |
| 7 | 镜像 OCID | `ocid1.image.oc1…` | CLI 查询 | 实例的系统 |
| 8 | 实例 SSH 公钥 | `ssh-ed25519 AAAA…` | `ssh-keygen` 生成 | 抢到后登录实例 |

三处来源说明：

- 第 1 至 4 项从控制台获取。见第 3 章。
- 第 5 至 7 项由部署器自动查询。手动使用时，用第 9 章的 CLI 命令查询。
- 第 8 项由部署器自动生成。

### 2.2 信息对照检查清单

复制本清单，逐项勾选。全部勾选后，信息收集完成。

- [ ] **租户 OCID** 已复制
  - 前缀为 `ocid1.tenancy.oc1..`。粘贴后检查无多余空格。
- [ ] **用户 OCID** 已复制
  - 前缀为 `ocid1.user.oc1..`。
- [ ] **区域代码** 已确认
  - 形如 `us-phoenix-1`。不是显示名。
- [ ] **API 私钥文件** 已保存
  - 已执行 `chmod 600`。文件只下载一次，丢失无法找回。
- [ ] **API 公钥** 已回填
  - 公钥内容已粘贴回"添加 API 密钥"对话框，并已点击"添加"。
- [ ] **指纹** 已出现在密钥列表
  - 形如 `ab:cd:…`，共 16 组十六进制数。
- [ ] **认证已通过**
  - `oci iam region list` 有输出。
- [ ] **可用性域** 已记录
  - 形如 `XXXX:PHX-AD-1`。建议记录全部 AD。
- [ ] **子网 OCID** 已有
  - `禁公网` 列为 `false`（公有子网）。
- [ ] **镜像 OCID** 已有
  - 名称含 `aarch64`，不含 `Minimal`。
- [ ] **实例 SSH 公钥** 已生成
  - 文件以 `.pub` 结尾。
- [ ] （可选）**离线自检已通过**
  - `bash tests/catcher-selftest.sh` 输出 6/6。

## 3. 🔍 逐项获取详解

控制台有两个界面版本。两个版本的入口不同。以下每项都给出两条路径：**经典界面**与**新版界面**。
新版界面是 Identity Domain 版本。按你实际看到的界面操作。

### 3.1 租户 OCID（Tenancy OCID）

📍 **位置**　控制台右上角头像菜单。

🧭 **步骤 · 经典界面**

1. 点击右上角头像。
2. 点击菜单顶部的 **Tenancy: 你的租户名**。
3. 在 **Tenancy Information** 区域找到 **OCID**。
4. 点击 **Copy**。

🧭 **步骤 · 新版界面**

1. 点击右上角头像。
2. 在弹出的概要面板中点击 **租户：你的租户名**。
3. 页面打开"租户详细信息"。找到 **OCID** 行。
4. 点击 OCID 右侧的复制按钮。

👀 **形态**　`ocid1.tenancy.oc1..` 开头，后接一串小写字母与数字。总长约 70 字符。

✅ **验证**　粘贴到文本编辑器检查两点：前缀正确；没有多余空格。

> ⚠️ **注意**　"租户名"（例如 `w12345678`）不是 OCID。OCID 以 `ocid1.tenancy.` 开头。

### 3.2 用户 OCID（User OCID）

📍 **位置**　控制台右上角头像菜单，用户设置页。

🧭 **步骤 · 经典界面**

1. 点击右上角头像。
2. 点击 **User settings**。
3. 找到 **OCID**，点击 **Copy**。

🧭 **步骤 · 新版界面**

1. 点击右上角头像。
2. 点击 **用户设置**。页面名称为"我的概要信息"。
3. 找到 **OCID** 行，点击复制按钮。

👀 **形态**　`ocid1.user.oc1..` 开头。

✅ **验证**　前缀为 `ocid1.user.`。

> ⚠️ **注意**　页面上还有身份域 ID、组 ID 等其他标识。认准 `ocid1.user.` 前缀。

### 3.3 区域代码（Region）

📍 **位置**　控制台右上角的区域菜单，例如显示 `US West (Phoenix)`。

🧭 **步骤**

1. 记录区域菜单的显示名。
2. 读取区域代码。两种方法：
   - 方法一（最快）：查看浏览器地址栏。控制台 URL 通常带 `?region=us-phoenix-1` 参数。参数值就是区域代码。
   - 方法二：打开控制台中任意资源页面，切换区域菜单，观察 URL 变化。

👀 **形态**　小写字母、连字符与数字。例如 `us-phoenix-1`、`ap-tokyo-1`、`ap-singapore-1`、`uk-cardiff-1`。

✅ **验证**　格式为 `xx-xxxx-N`。

> ⚠️ **注意**　填入显示名（`US West (Phoenix)`）会导致认证失败。必须填区域代码。

### 3.4 API 密钥对与指纹（重点章节）

本节有两个获取路径。任选一个。

先读三条关键提醒：

> **🚨 关键提醒**
>
> 1. 控制台"生成 API 密钥对"会下载**两个文件**：私钥（无后缀或 `-private.pem`）和公钥（`-public.pem`）。**两个文件都要保存。**
> 2. **指纹不在文件中。** 必须把**公钥内容粘贴回"添加 API 密钥"对话框**，点击"添加"之后，控制台才完成登记，并在密钥列表显示**指纹**。
> 3. **私钥只提供一次下载。** 之后永不显示。丢失后只能删除该密钥并重新生成。下载后立即执行 `chmod 600`。

> **界面差异提醒**　控制台版本不同，对话框名称可能略有差别。以对话框实际提示为准。

#### 路径一：控制台生成密钥对

🧭 **步骤 · 经典界面**

1. 进入 **User settings** 页。
2. 左侧点击 **API Keys**。
3. 点击 **Add API Key**。
4. 选择 **Generate API key pair**。
5. 点击 **Download private key**，保存 `.pem` 文件。妥善保管。
6. 下载或复制**公钥文件**的内容。
7. 把公钥内容**粘贴回对话框**，点击 **Add**。
8. 在密钥列表记录 **Fingerprint**（指纹）。

🧭 **步骤 · 新版界面**

1. 进入 **用户设置**（我的概要信息）页。
2. 打开 **令牌和密钥**。
3. 进入 **API 密钥** 区，点击添加按钮。
4. 选择 **生成 API 密钥对**。
5. 下载**私钥文件**并保存。
6. 下载或复制**公钥内容**，粘贴回对话框。
7. 点击**添加**。
8. 在密钥列表记录**指纹**。

👀 **形态**　私钥以 `-----BEGIN PRIVATE KEY-----` 开头。指纹形如 `ab:cd:…`，共 16 组两位十六进制数。

✅ **验证**　认证命令：`oci iam region list`。有区域列表输出即成功。

> ⚠️ **注意**
>
> - 私钥文件立即执行 `chmod 600`。
> - 使用部署器的 `--key` 参数复用此私钥时，部署器自动计算指纹。不需要手工抄写指纹。

#### 路径二：服务器生成密钥对（推荐）

本路径私钥从生成到使用都不离开服务器。操作者只传递公钥文本。

🧭 **步骤**

1. 运行部署器：`bash oci-arm-auto.sh`。不要传 `--key` 参数。
2. 部署器在服务器生成密钥对，并打印**公钥全文**。
3. 按路径一的第 1 至 3 步进入添加页。选择 **粘贴公钥**。
4. 把公钥**整段**粘贴进对话框，点击**添加**。
5. 指纹由部署器自动计算。控制台显示值与部署器输出值一致。

✅ **验证**　同样使用 `oci iam region list`。

> ⚠️ **认证失败排查顺序**
>
> 1. 公钥是否整段粘贴。检查首尾行。
> 2. 是否点击了"添加"。
> 3. `~/.oci/config` 中的 `fingerprint` 与密钥是否匹配。部署器自动生成的不会错。
> 4. `key_file` 权限是否为 600。

### 3.5 可用性域（AD）

📍 **位置**　命令行查询。

```bash
oci iam availability-domain list --query "data[].name" --output table
```

👀 **形态**　形如 `XXXX:PHX-AD-1`。`XXXX` 是租户的随机前缀。

✅ **验证**　输出 1 至 3 行。

> ⚠️ **注意**　把**全部 AD** 填入配置，逗号分隔。核心脚本依次轮换。命中率高于只用一个 AD。

### 3.6 子网 OCID（Subnet）

📍 **位置**　命令行查询。

```bash
oci network subnet list --compartment-id <租户OCID> --all \
  --query "data[].{名称:\"display-name\", OCID:id, 禁公网:\"prohibit-public-ip-on-vnic\"}" \
  --output table
```

👀 **形态**　`ocid1.subnet.oc1.<区域>…`。

✅ **验证**　选择 **禁公网 = false** 的行。该子网是公有子网。

> ⚠️ **注意**　没有公有子网时，先在控制台创建。
> 路径：网络 → 虚拟云网络 → 创建 VCN。默认向导会附带一个公有子网。

### 3.7 镜像 OCID（Image）

📍 **位置**　命令行查询。

```bash
oci compute image list --compartment-id <租户OCID> \
  --operating-system "Canonical Ubuntu" --shape "VM.Standard.A1.Flex" \
  --sort-by TIMECREATED --sort-order DESC \
  --query "data[0:5].{名称:\"display-name\", OCID:id}" --output table
```

👀 **形态**　名称形如 `Canonical-Ubuntu-24.04-aarch64-2026.09.18-0`。OCID 以 `ocid1.image.oc1…` 开头。

✅ **验证**　名称含 `aarch64`，且不含 `Minimal`。这是完整版 ARM 镜像。

> ⚠️ **注意**　Oracle Linux 镜像把 `--operating-system` 改为 `"Oracle Linux"`。
> 部署器会自动选版本最高的完整版镜像。可以用 `--os` 或 `--image` 干预。

### 3.8 实例 SSH 密钥

📍 **位置**　在部署机上生成。

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

👀 **形态**　公钥文件 `~/.ssh/id_ed25519.pub`，以 `ssh-ed25519` 开头。私钥为同名无 `.pub` 文件。

✅ **验证**　`cat ~/.ssh/id_ed25519.pub` 有输出。

> ⚠️ **注意**　把私钥备份到本机。实例上只保存公钥。

## 4. 🚀 三种使用路径

### 4.1 全手动

适合希望理解原理的操作者。

```bash
# 第一步：安装 OCI CLI。使用 PyPI 官方包，不需要 git。
python3 -m venv ~/.local/share/oci-cli-venv
~/.local/share/oci-cli-venv/bin/pip install oci-cli
export PATH="$HOME/.local/share/oci-cli-venv/bin:$PATH"

# 第二步：写入 ~/.oci/config。五项内容见 README。然后设置权限。
chmod 600 ~/.oci/oci_api_key.pem ~/.oci/config
oci iam region list    # 验证认证

# 第三步：查询三项 OCID。命令见 3.5 至 3.7。

# 第四步：准备核心脚本与配置。
mkdir -p ~/oci-arm-catcher && cd ~/oci-arm-catcher
# 把 oci-arm-catcher.sh 放入本目录。创建 .env 文件，写入 README 中的配置键。

# 第五步：试跑一次，然后后台挂机。
./oci-arm-catcher.sh --once
nohup ./oci-arm-catcher.sh > catcher.log 2>&1 &
```

### 4.2 脚本化交互

整机部署：

```bash
bash oci-arm-auto.sh
```

部署器依次提示三项操作：粘贴公钥确认、回车、输入三个标识。每项都标注控制台位置。

只运行核心脚本：

```bash
./oci-arm-catcher.sh
```

核心脚本逐项询问缺失配置。每项提示获取位置。

### 4.3 浏览器全自动

前提：本机安装 Tabbit，且已登录控制台。

```bash
bash oci-info-from-tabbit.sh -o oci-info.env
scp -i <KEY> oci-arm-auto.sh oci-arm-catcher.sh oci-info.env ubuntu@<SERVER>:~/
ssh -t -i <KEY> ubuntu@<SERVER> "source ~/oci-info.env && bash ~/oci-arm-auto.sh"
```

提取器读取四项信息：租户 OCID、用户 OCID、区域代码、控制台指纹。完成后恢复浏览器标签页。

## 5. 🤖 Agent 使用指南

适用对象：能执行命令的 AI Agent，例如 Claude Code、ZCode。

Agent 代替你执行四项工作：上传脚本、运行部署、回报每一步结果、管理后台进程。

你只需要把信息整理成提示词。

### 5.1 模板 A：全自动部署（推荐）

```text
帮我部署甲骨文云 ARM 抢购工具包。

【服务器】ubuntu@<SERVER>，SSH 私钥：<本机私钥路径>
【工具包】本机 oci-kit 目录下的 oci-arm-auto.sh 与 oci-arm-catcher.sh
【接入信息】（OCID 非机密，可安全传递）
OCI_USER_OCID=<用户OCID>
OCI_TENANCY_OCID=<租户OCID>
OCI_REGION=<区域代码>
【API 密钥处理】按我选的方式执行：
  a) 服务器生成新密钥。把公钥给我。我去控制台粘贴。（推荐）
  b) 使用已有私钥：<本机私钥路径>。请 scp 到服务器后部署。
【流程要求】
1. 把两个脚本 scp 到服务器同一目录。
2. 先用 --no-start 部署，回报每一步结果。
3. 我在控制台完成粘贴公钥后，你继续。
4. 完成后台启动。回报三项：进程状态、日志首屏、查看日志的命令。
```

### 5.2 模板 B：巡检

```text
请登录 <用户>@<服务器>（密钥 <本机私钥路径>），完成以下巡检：
1. 检查 ~/oci-arm-catcher/.env 的每一行是否非空。
2. 运行 ./oci-arm-catcher.sh --once。退出码含义：0 抢到；3 容量不足；1 其他错误。
3. 汇报容量状态与最近 20 行日志。
```

### 5.3 模板 C：从零收集信息

```text
我要抢甲骨文 ARM 实例，但没有现成配置。请你：
1. 引导我在控制台逐步获取：租户 OCID、用户 OCID、区域代码、API 密钥。
   提醒我三点：私钥和公钥两个文件都要保存；公钥要回填；添加之后才显示指纹。
2. 我提供信息后，按 oci-arm-kit 的标准流程完成部署。
```

### 5.4 注意事项

- 可以传递：OCID、区域代码、指纹、"请生成新密钥"的指令。
- 不要传递：私钥文件内容。让 Agent 用 `scp` 传文件，不要粘贴私钥文本。
- Agent 应能解释退出码：`0` 成功，`1` 错误，`3` 容量不足。
- 日志出现 `LimitExceeded` 后停止属正常行为。
- 本工具包不需要任何"下载即执行"操作。适配禁止 `curl | bash` 的安全策略。

## 6. ⚙️ 运行与运维

| 动作 | 命令 |
|---|---|
| 后台启动（断开 SSH 后继续） | `cd ~/oci-arm-catcher && nohup ./oci-arm-catcher.sh > catcher.log 2>&1 < /dev/null &` |
| 实时查看日志 | `tail -f ~/oci-arm-catcher/catcher.log` |
| 停止 | `pkill -f oci-arm-catcher` |
| 试跑一次 | `./oci-arm-catcher.sh --once`。用 `echo $?` 查看退出码 |
| 重新部署 | `bash ~/oci-arm-auto.sh`。部署器可重复执行 |

日志的正常形态：

```text
==> [2026-01-01 12:00:00] 第 1 次尝试（AD: XXXX:PHX-AD-1）
  → InternalError: Out of host capacity.          ← 可以重试。等待后轮换 AD。
==> 等待 5 分钟后重试（Ctrl+C 可停止）
...
  SUCCESS! Instance created: ocid1.instance.oc1…   ← 创建成功。脚本退出。
```

创建成功后的三项操作：

1. 控制台进入 Compute → Instances，确认实例存在。
2. 登录实例：

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<实例公网IP>   # Ubuntu 镜像。Oracle Linux 用户为 opc。
```

3. 确认抢购进程已退出：`pkill -f oci-arm-catcher`。

## 7. 🩺 排错手册

| 症状 | 原因 | 处理 |
|---|---|---|
| `oci: command not found` | CLI 不在 PATH | `export PATH="$HOME/.local/bin:$PATH"`。部署器自动处理 |
| `oci iam region list` 认证失败 | 公钥未添加、粘贴不全、或指纹错 | 回控制台核对。重跑部署器可重试 |
| `Config file not found` | 未生成 `~/.oci/config` | 运行部署器，或按 4.1 手动创建 |
| 日志持续输出 `Out of host capacity` | 该区域 ARM 暂无容量 | 保持运行。这是正常状态。多填几个 AD 提高命中率 |
| 日志 `LimitExceeded` 后停止 | 免费额度已满。2 OCPU + 12GB 已占用 | 删除不再使用的 A1 实例后再抢。按需付费账户注意费用 |
| `SSH_KEY_FILE` 不存在 | 公钥路径错或未生成 | `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""` |
| `SUBNET_ID 格式不对` | 填入了 VCN 的 OCID | 子网以 `ocid1.subnet.` 开头，不是 `ocid1.vcn.` |
| 提取器找不到标签页 | Tabbit 未登录控制台 | 先在 Tabbit 登录 `cloud.oracle.com`，再运行提取器 |
| 抢到后无法登录 | 用户名或私钥不对 | Ubuntu 镜像用 `ubuntu`。Oracle Linux 用 `opc`。使用与 `.env` 中公钥配对的私钥 |
| 脚本次日消失 | 未用 nohup，或机器重启 | 使用第 6 章的 nohup 命令挂机 |

## 8. 🔒 安全须知

1. 私钥等于账号钥匙。执行 `chmod 600`。只存服务器。不入仓库。不粘贴到聊天。
2. OCID 与指纹非机密。整份 `.env` 仍建议按凭据件管理：权限 600，不提交 git。
3. 不再使用的 API 密钥及时删除。控制台 API 密钥页每行有删除按钮。
4. 按需付费账户超配会产生费用。抢购前到账单页确认额度口径。

## 9. 📎 附录：命令速查

```bash
# 信息收集
oci iam availability-domain list --query "data[].name" --output table
oci network subnet list --compartment-id <租户OCID> --all --output table
oci compute image list --compartment-id <租户OCID> --operating-system "Canonical Ubuntu" \
  --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC \
  --query "data[0:5].{名称:\"display-name\", OCID:id}" --output table

# 认证
oci iam region list

# 运行
./oci-arm-catcher.sh --once
nohup ./oci-arm-catcher.sh > catcher.log 2>&1 < /dev/null &
tail -f catcher.log
pkill -f oci-arm-catcher

# 离线自检（不触网）
bash tests/catcher-selftest.sh
```

官方文档：[OCI CLI 安装与配置](https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm) · [始终免费资源说明](https://docs.cloud.oracle.com/iaas/Content/FreeTier/freetier.htm)