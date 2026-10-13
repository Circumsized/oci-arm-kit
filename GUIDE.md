# oci-arm-kit 使用指南

这份指南覆盖从收集接入信息到挂机抢购的全部环节：每项信息在控制台哪里找、三种使用路径怎么选、交给 Agent 怎么做、卡住了怎么排查，以及还没有账号时怎么注册。

文中出现的尖括号都是占位符，替换成你自己的值即可。

动手之前记住两条界线：OCID 和指纹不是机密，随便复制、发给 Agent 都没问题；私钥是机密，不要贴进聊天窗口，也不要提交到代码仓库。

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
10. [附录：注册账号导读](#10--附录注册账号导读)

## 1. 📖 前置知识

先过一遍术语，后面各章都按这里的叫法来，不再换同义词。

| 术语 | 说明 |
|---|---|
| **OCID** | Oracle Cloud 中每个资源的唯一标识。格式为 `ocid1.<类型>.oc1..<随机串>`。本工具用到三类：租户 OCID、用户 OCID、资源 OCID（子网、镜像）。 |
| **Always Free** | 甲骨文云永久免费额度。ARM 规格为 `VM.Standard.A1.Flex`。2026-06 起，全部 A1 实例合计上限 2 OCPU + 12GB。超配请求返回 `LimitExceeded`。 |
| **OCPU** | Oracle 的计算容量单位。1 OCPU（x86）约等于 2 个物理核心。A1（ARM）的 1 OCPU 等于 1 个物理核心。 |
| **区域代码** | 形如 `us-phoenix-1`。控制台右上角显示的是区域显示名，例如 `US West (Phoenix)`。脚本使用区域代码。对应关系见 3.3。 |
| **Home Region** | 注册账号时选定的主区域。**选定后不可更改。** Always Free 实例只能在 Home Region 创建。 |
| **可用性域（AD）** | 区域内的物理隔离机房分组，形如 `XXXX:PHX-AD-1`。ARM 容量按 AD 独立计算。一个 AD 容量不足时，另一个 AD 可能仍有容量。核心脚本轮换 AD 重试。 |
| **容错域（FD）** | AD 内的机架分组。系统自动分配。对单台实例无影响。不需要配置。 |
| **区间（Compartment）** | 资源的逻辑分组。根区间就是租户本身。本工具默认使用根区间（`COMPARTMENT_ID` 填租户 OCID）。 |
| **VCN 与子网** | 虚拟云网络（VCN）是你账号内的私有网络。子网是 VCN 内的网段。实例必须接入一个子网。要拿到公网 IP，子网必须是**公有子网**。 |
| **Out of host capacity** | 当前 AD 没有 ARM 空闲容量。该错误可以重试。核心脚本等待后继续尝试。 |
| **按需付费（PAYG）** | 绑定有效支付方式并可随时开通收费资源的账户类型。Always Free 账户超配请求会被拒绝；按需付费账户超配会产生**实际费用**。 |
| **Tabbit 浏览器** | 一款浏览器。本工具包的提取器可驱动它读取已登录的控制台页面。不需要它也可以使用本工具包（见方式 B）。 |

额度要分两个口径来看。实例集上限是全部 A1 实例合计 2 OCPU + 12GB（2026-06 起），超配会返回 `LimitExceeded`，核心脚本据此停止。月度用量池则看你自己账号控制台横幅上的数字（2026-10 实测为 3000 OCPU 小时 + 18000 GB 小时），这个数字随 Oracle 政策变化，旧教程可能写别的值（比如 1500 + 9000）。以你账号的横幅为准——单台 A1 常驻运行离用量池上限还远得很。

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

来源说明：

- 第 1 至 3 项是三个字符串，需要你从控制台手动复制，方法见第 3 章。
- 第 4 项（API 密钥）有两条获取路径，见 3.4。
- 第 5 至 8 项不用操心：用部署器时它会自动查询或生成；纯手工配置时，照第 9 章的 CLI 命令查一遍即可。

### 2.2 信息对照检查清单

拿这份清单逐项核对，全部勾上就说明信息齐了。用部署器的话，只有第 1 至 4 项需要你经手。

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
  - `bash tests/catcher-selftest.sh` 输出 8/8。

## 3. 🔍 逐项获取详解

控制台目前有两代界面，入口不一样，所以每项都给出两套步骤。想知道自己用的是哪代，点开右上角头像看菜单第一项：显示 `Tenancy: 你的租户名`（英文）就是经典界面，显示 `租户：你的租户名`（中文）就是新版界面（Identity Domain 版本），照着对应那一列操作即可。

| 你看到的文案 | 你的界面 | 看哪套步骤 |
|---|---|---|
| `Tenancy: 你的租户名`（英文） | 经典界面 | 每项的「经典界面」步骤 |
| `租户：你的租户名`（中文） | 新版界面（Identity Domain 版本） | 每项的「新版界面」步骤 |

3.3 至 3.8 的步骤与界面版本无关，两代通用。

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
> Always Free 实例只能在 Home Region 创建。区域菜单中 Home Region 会标注 "Home" 或排在最前。

### 3.4 API 密钥对与指纹（重点章节）

这里容易踩坑，先讲清楚三件事，再给两条获取路径。

控制台"生成 API 密钥对"会一次性下载两个文件：私钥（无后缀或 `-private.pem`）和公钥（`-public.pem`）。两个都要存下来——公钥后面要粘贴回对话框，不保存就没有内容可粘。

指纹不在任何文件里。把公钥粘贴回"添加 API 密钥"对话框、点击添加之后，控制台完成登记，指纹才会出现在密钥列表里。

私钥只提供这一次下载，之后永远不再显示，丢了只能删掉这把密钥重新生成。下载完马上 `chmod 600`。

> 控制台版本不同，对话框名称可能略有差别，以实际提示为准。

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

这条路里私钥从生成到使用都不离开服务器，你经手的只有一段公钥文本。

🧭 **步骤**

1. 运行部署器：`bash oci-arm-auto.sh`。不要传 `--key` 参数。
2. 部署器在服务器生成密钥对，并打印**公钥全文**。
3. 进入控制台的添加 API 密钥对话框（入口见路径一的第 1 至 2 步，经典或新版任选）。
4. 选择 **粘贴公钥** 选项（对话框中的第二个选项，与"生成 API 密钥对"并列）。
5. 把公钥**整段**粘贴进对话框，点击**添加**。
6. 指纹由部署器自动计算。控制台显示值与部署器输出值一致。

✅ **验证**　同样使用 `oci iam region list`。

#### 401 NotAuthenticated 逐字段检查

认证失败基本都出在 `~/.oci/config` 这五个字段上，任何一项写错都会得到 `401 NotAuthenticated`。

| 字段 | 值 | 常见错误 |
|---|---|---|
| `user` | 用户 OCID | 与 tenancy 填反 |
| `tenancy` | 租户 OCID | 与 user 填反 |
| `fingerprint` | 密钥指纹 | 抄错一位；或与私钥不匹配 |
| `key_file` | 私钥文件路径 | 路径错；权限不是 600 |
| `region` | 区域代码 | 填了显示名（见 3.3） |

文件示例：

```ini
[DEFAULT]
user=ocid1.user.oc1..xxxx
fingerprint=ab:cd:ef:...
tenancy=ocid1.tenancy.oc1..xxxx
region=us-phoenix-1
key_file=/home/ubuntu/.oci/oci_api_key.pem
```

> ⚠️ **认证失败排查顺序**
>
> 1. 公钥是否整段粘贴（检查首尾行）。
> 2. "添加"按钮是否点过。
> 3. `~/.oci/config` 五项是否与上表一致（部署器自动生成的不会错）。
> 4. `key_file` 权限是否为 600。

### 3.5 可用性域（AD）

📍 **位置**　命令行查询。

```bash
oci iam availability-domain list --query "data[].name" --output table
```

👀 **形态**　形如 `XXXX:PHX-AD-1`。`XXXX` 是租户的随机前缀。

✅ **验证**　输出 1 至 3 行。

> ⚠️ **注意**　把全部 AD 都填进配置（逗号分隔），核心脚本会依次轮换，命中率比死守一个 AD 高得多。

### 3.6 子网 OCID（Subnet）

📍 **位置**　命令行查询。

```bash
oci network subnet list --compartment-id <租户OCID> --all \
  --query "data[].{名称:\"display-name\", OCID:id, 禁公网:\"prohibit-public-ip-on-vnic\"}" \
  --output table
```

👀 **形态**　`ocid1.subnet.oc1.<区域>…`。

✅ **验证**　选 **禁公网 = false** 的行，那就是公有子网。

> ⚠️ **注意**　如果查不到公有子网，先去控制台建一个：网络 → 虚拟云网络 → 创建 VCN，默认向导会顺带生成一个公有子网。

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

> ⚠️ **注意**　想用 Oracle Linux 就把 `--operating-system` 换成 `"Oracle Linux"`。用部署器的话它会自动挑版本最高的完整版镜像，也可以用 `--os` 或 `--image` 手动指定。

### 3.8 实例 SSH 密钥

📍 **位置**　在运行抢购的服务器上生成。

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

👀 **形态**　公钥文件 `~/.ssh/id_ed25519.pub`，以 `ssh-ed25519` 开头。私钥为同名无 `.pub` 文件。

✅ **验证**　`cat ~/.ssh/id_ed25519.pub` 有输出。

> ⚠️ **注意**　抢到实例后，用这台跑抢购的服务器上的私钥登录，实例里只存了公钥。想从本机登录就把 `~/.ssh/id_ed25519` 拷回本机。

### 3.9 Stack OCID（可选，适用于 Stack Apply 模式）

不想在命令行里逐个填子网、镜像和 AD 的话，可以改走 Stack 路线：在控制台预先存好一个资源堆栈（Stack），抢购时只给它一个 OCID。

📍 **位置**　控制台导航菜单 → **Developer Services** → **Resource Manager** → **Stacks**。

🧭 **步骤**

1. 点击 **Create Stack**，按预置模板或自定义配置实例（Shape 选 `VM.Standard.A1.Flex`，2 OCPU + 12GB，粘贴 SSH 公钥）。
2. 建好后进入该 Stack 详情页，找到 **OCID** 复制下来。
3. 剩下的事核心脚本已经内置，它执行的正是这条命令：
   ```bash
   oci resource-manager job create-apply-job \
     --stack-id "$STACK_OCID" \
     --execution-plan-strategy AUTO_APPROVED
   ```

👀 **形态**　以 `ocid1.ormstack.oc1…` 开头。

✅ **验证**　前缀是 `ocid1.ormstack.`。把它传给核心脚本：`./oci-arm-catcher.sh --stack-id "$STACK_OCID"`。

## 4. 🚀 三种使用路径

工具包从这里拿：

```bash
git clone https://github.com/Circumsized/oci-arm-kit.git
cd oci-arm-kit
```

没有 git 就在仓库页面点 **Code → Download ZIP** 解压。

核心脚本有两种底层引擎，按习惯选一种。Direct Launch（默认）直接调 Compute API，能在多个可用性域之间轮换重试，命中率最高；Stack Apply 只认一个 `STACK_OCID`，子网和镜像全在 Stack 模板里，执行的命令就是：

```bash
oci resource-manager job create-apply-job \
  --stack-id "$STACK_OCID" \
  --execution-plan-strategy AUTO_APPROVED
```

本地不需要配子网和镜像，脚本会自动退避循环。

抢购要长期挂着，别拿自己的电脑 24 小时开机。开一台 Always Free E2.Micro（1/8 OCPU + 1GB）当引导机就行，每账号最多 2 台，注意它也得建在 Home Region。部署器和核心脚本只依赖 bash、python3 和 OCI CLI，E2.Micro 完全跑得动；只是 1GB 内存装 OCI CLI 会有点紧，装不动就先加 1GB swap 再重跑部署器。

### 4.1 全手动

想理解每一步原理的话走这条。

```bash
# 第一步：安装 OCI CLI。使用 PyPI 官方包，不需要 git。
python3 -m venv ~/.local/share/oci-cli-venv
~/.local/share/oci-cli-venv/bin/pip install oci-cli
export PATH="$HOME/.local/share/oci-cli-venv/bin:$PATH"

# 第二步：写入 ~/.oci/config。五项字段清单见 3.4。然后设置权限。
chmod 600 ~/.oci/oci_api_key.pem ~/.oci/config
oci iam region list    # 验证认证

# 第三步：查询三项 OCID。命令见 3.5 至 3.7。

# 第四步：准备核心脚本与配置。
mkdir -p ~/oci-arm-catcher && cd ~/oci-arm-catcher
cp <工具包目录>/oci-arm-catcher.sh .
# 创建 .env 文件。写入 README 配置表中的键值。

# 第五步：试跑一次，然后后台挂机。
./oci-arm-catcher.sh --once
nohup ./oci-arm-catcher.sh > catcher.log 2>&1 &
```

### 4.2 脚本化交互

对应 README 的**方式 B**。不需要 Tabbit。需要浏览器完成一次粘贴公钥。

整机部署：

```bash
scp -i <KEY> oci-arm-auto.sh oci-arm-catcher.sh ubuntu@<SERVER>:~/
ssh -t -i <KEY> ubuntu@<SERVER> "bash ~/oci-arm-auto.sh"
```

部署器会分三次向你提问：粘贴公钥后的确认、一次回车、三个标识（用户 OCID、租户 OCID、区域代码），每个都在屏幕上标了控制台位置。装完它会自动把抢购挂到后台，之后用第 6 章的进程检查命令确认一下就行。

想单独跑核心脚本（前提是部署器跑过，或已按 4.1 手工配好）：

```bash
cd ~/oci-arm-catcher && ./oci-arm-catcher.sh
```

它会逐项询问缺失的配置，每项都提示去哪里找。

### 4.3 浏览器全自动

对应 README 的**方式 A**，前提是本机装了 Tabbit 且已登录控制台。

```bash
bash oci-info-from-tabbit.sh -o oci-info.env
scp -i <KEY> oci-arm-auto.sh oci-arm-catcher.sh oci-info.env ubuntu@<SERVER>:~/
ssh -t -i <KEY> ubuntu@<SERVER> "source ~/oci-info.env && bash ~/oci-arm-auto.sh"
```

提取器会读出四项信息：租户 OCID、用户 OCID、区域代码和控制台已有的指纹，读完把浏览器标签页恢复原状。

指纹的作用是告诉你控制台里已经注册过哪些 API 密钥。看到有旧指纹且你手上还留着对应的私钥文件，可以直接复用：`bash oci-arm-auto.sh --key <私钥路径>`；否则照常生成新密钥即可。

## 5. 🤖 Agent 使用指南

只要你用的 AI Agent 能执行命令（Claude Code、ZCode 之类），上传脚本、跑部署、汇报结果、管后台进程这些事都可以交给它，你负责把信息整理成提示词。

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
4. 完成后台启动。回报四项：进程状态（pgrep -af oci-arm-catcher）、日志首屏、
   查看日志的命令、停止抢购的命令。
```

### 5.2 模板 B：巡检

```text
请登录 <用户>@<服务器>（密钥 <本机私钥路径>），完成以下巡检：
1. 检查 ~/oci-arm-catcher/.env 的每一行是否非空。
2. 运行 pgrep -af oci-arm-catcher 确认进程存活。
3. 运行 ./oci-arm-catcher.sh --once。退出码含义：0 抢到；3 容量不足；1 其他错误。
4. 汇报容量状态与最近 20 行日志。
```

### 5.3 模板 C：从零收集信息

```text
我要抢甲骨文 ARM 实例，但没有现成配置。请你：
1. 引导我在控制台逐步获取：租户 OCID、用户 OCID、区域代码、API 密钥。
   提醒我三点：私钥和公钥两个文件都要保存；公钥要回填；添加之后才显示指纹。
2. 我提供信息后，按 oci-arm-kit 的标准流程完成部署。
```

### 5.4 注意事项

OCID、区域代码、指纹、"请生成新密钥"这类指令都可以放心交给 Agent。私钥不一样：让 Agent 用 `scp` 传文件，不要把私钥文本贴进对话。

Agent 应该能说清退出码的含义：`0` 成功、`1` 出错、`3` 容量不足；日志出现 `LimitExceeded` 后停止是正常行为，不是故障。

工具包全程不涉及任何"下载即执行"操作，在禁止 `curl | bash` 的安全策略下也能用。

## 6. ⚙️ 运行与运维

| 动作 | 命令 |
|---|---|
| 后台启动（断开 SSH 后继续） | `cd ~/oci-arm-catcher && nohup ./oci-arm-catcher.sh > catcher.log 2>&1 < /dev/null &` |
| 实时查看日志 | `tail -f ~/oci-arm-catcher/catcher.log` |
| **检查进程是否存活** | `pgrep -af oci-arm-catcher`。有输出 = 在跑；无输出 = 已停止 |
| 停止 | `pkill -f oci-arm-catcher` |
| 试跑一次 | `./oci-arm-catcher.sh --once`。用 `echo $?` 查看退出码 |
| 重新部署 | `bash ~/oci-arm-auto.sh`。部署器可重复执行 |

> 部署器收尾时会用 nohup 自动把抢购挂到后台，之后关掉 SSH 也不受影响；只有 `--no-start` 模式需要你手动启动。

日志的正常形态：

```text
==> [2026-01-01 12:00:00] 第 1 次尝试（AD: XXXX:PHX-AD-1）
  → InternalError: Out of host capacity.          ← 可以重试。等待后轮换 AD。
==> 等待 5 分钟后重试（Ctrl+C 可停止）
...
  SUCCESS! Instance created: ocid1.instance.oc1…   ← 创建成功。脚本退出。
```

这里的节奏是每次只提交一次请求，等结果，退避，换下一个可用性域。连续请求会触发限流，反而更难抢到。

抢到之后有三件事要做。先到控制台 Compute → Instances 确认实例存在，顺手在详情页记下公网 IP（"公用 IP 地址"字段）。然后从那台跑抢购的服务器登录，私钥就在它的 `~/.ssh/id_ed25519`：

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<实例公网IP>   # Ubuntu 镜像。Oracle Linux 用户为 opc。
```

收尾时确认抢购进程确实退出了——脚本在创建成功后会自动退出，下面两条命令用于确认或强制终止：

```bash
pgrep -af oci-arm-catcher     # 无输出 = 已退出
pkill -f oci-arm-catcher      # 需要强制终止时使用
```

4. 别忘了风险：Always Free 实例长期低负载可能被 Oracle 判定闲置并回收，它不适合跑生产业务，有重要数据就定期备份。

## 7. 🩺 排错手册

| 症状 | 原因 | 处理 |
|---|---|---|
| `oci: command not found` | CLI 不在 PATH | 部署器装的用 `export PATH="$HOME/.local/bin:$PATH"`；4.1 手动装的用 `export PATH="$HOME/.local/share/oci-cli-venv/bin:$PATH"` |
| `401 NotAuthenticated`，或 `oci iam region list` 认证失败 | config 五项里有一项写错 | 按 3.4 的"401 逐字段检查"表逐项核对；重跑部署器可重试 |
| `Config file not found` | 没生成 `~/.oci/config` | 跑部署器，或按 4.1 手动创建 |
| 日志一直输出 `Out of host capacity` | 该区域 ARM 暂时没容量 | 保持运行，这是正常状态；多填几个 AD 提高命中率 |
| 日志 `LimitExceeded` 后停止 | 免费额度已满（2 OCPU + 12GB 被占用） | 删掉不用的 A1 实例再抢；按需付费账户留意费用 |
| 超过一周都没容量 | 该区域整体紧张 | 只能等。Always Free 实例不能换区域（Home Region 固定），继续挂机是唯一办法 |
| `SSH_KEY_FILE` 不存在 | 公钥路径错或没生成 | `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""` |
| `SUBNET_ID 格式不对` | 填成了 VCN 的 OCID | 子网以 `ocid1.subnet.` 开头，不是 `ocid1.vcn.` |
| 提取器找不到标签页 | Tabbit 没登录控制台 | 先在 Tabbit 登录 `cloud.oracle.com` 再运行 |
| 抢到后无法登录 | 用户名、私钥或网络规则不对 | Ubuntu 镜像用 `ubuntu`，Oracle Linux 用 `opc`；用与 `.env` 中公钥配对的私钥；检查子网安全列表是否放行 22 端口 |
| 脚本次日消失 | 没挂 nohup，或机器重启了 | 用第 6 章的 nohup 命令挂机，用 `pgrep -af oci-arm-catcher` 确认 |

## 8. 🔒 安全须知

1. 私钥就是账号钥匙：`chmod 600`，只存服务器，不入仓库，不贴聊天。
2. OCID 和指纹不算机密，但整份 `.env` 还是按凭据对待：权限 600，不提交 git。
3. 不再使用的 API 密钥及时删掉，控制台 API 密钥页每行都有删除按钮。
4. 不要升级成按需付费账户。工具包是按 Always Free 额度设计的；注册时绑卡不等于开始收费。
5. 不用的资源及时删：实例、引导卷、保留的公网 IP，这些要么单独计费要么占额度。
6. 偶尔看一眼费用：控制台 → Billing & Cost Management → Cost Analysis，额度内应显示 0 费用。
7. Always Free 实例可能被回收（见第 6 章末尾），重要数据定期备份。

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
pgrep -af oci-arm-catcher
pkill -f oci-arm-catcher

# 核心命令：Stack Apply 模式（Resource Manager）
oci resource-manager job create-apply-job \
  --stack-id "$STACK_OCID" \
  --execution-plan-strategy AUTO_APPROVED

# 离线自检（不触网）
bash tests/catcher-selftest.sh
```

官方文档：[OCI CLI 安装与配置](https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm) · [始终免费资源说明](https://docs.cloud.oracle.com/iaas/Content/FreeTier/freetier.htm)

## 10. 📝 附录：注册账号导读

已经有账号就跳过这章。没有的话从注册说起。

> 注册表单和政策由 Oracle 随时调整，以注册页实际显示为准（本文 as-of 2026-10）。

### 10.1 注册前准备

准备三样东西：一张能国际支付的银行卡（VISA 或 Mastercard，别用虚拟卡、一次性卡、预付卡）、真实的姓名地址手机号、一个常用邮箱。

### 10.2 注册步骤

1. 打开 Oracle 云注册页（搜索 "Oracle Cloud Free Tier"）。
2. 填国家、姓名、邮箱，点 **Verify my email**，去邮箱完成验证。
3. 设置密码和 **Cloud Account Name**（账号名，例如 `myoraclecloud`），自己记得住就行。
4. 选 **Home Region**。这一步最重要，原因见 10.3。
5. 填地址和手机号，地址与银行卡账单地址保持一致。
6. 填银行卡信息和账单地址，点 **Start my free trial**。

银行卡验证时可能出现一笔小额授权冻结，那是验证流程，不是扣费。

### 10.3 Home Region 为什么重要

Home Region 选定后不能改，Always Free 实例也只能建在这里，工具包用到的子网、镜像、实例全都在这个区域里。选错了，后面所有步骤都白做，所以动手前先想清楚要用哪个区域。

常见选择有 `Japan East (Tokyo)`、`Japan Central (Osaka)`、`Singapore`、`South Korea Central`。热门区域竞争更激烈，冷门区域反而更容易抢到。

### 10.4 注册被拒怎么办

先逐项核对：姓名是否真实、地址是否真实、地址与银行卡账单地址是否一致、手机号是否真实、银行卡是否支持国际支付、所有信息是否前后一致。

注册失败绝大多数是信息不一致造成的，别一失败就换邮箱换网络。另外 Oracle 规定一人只能有一个免费账户，反复注册新账号没有意义。

### 10.5 注册成功后

先开一台 E2.Micro 当引导机（1/8 OCPU + 1GB，每账号最多 2 台）：控制台 → Compute → Instances → 创建实例，镜像选 Ubuntu，规格选 `VM.Standard.E2.1.Micro`。之后用它来跑抢购工具包（见第 4 章）。

不要一上来就死磕 A1 Flex——先把引导机就位，再挂机慢慢抢。

### 10.6 额度与费用

注册时绑卡不等于开始收费。A1 Flex 的实例集上限是 2 OCPU + 12GB（2026-06 起），E2.Micro 最多 2 台；月度用量池的口径见第 1 章的"额度口径"引用块。

不要主动升级成付费账户，也不要创建超出 Always Free 范围的资源。不用的资源及时删掉，偶尔看一眼 Cost Analysis。