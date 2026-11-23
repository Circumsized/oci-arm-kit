# arm-free-catcher v4.0.0 SOP — 抢购作战手册

> 目标：以稳定、可控、可审计的方式抢购 Oracle Always Free 实例（A1.Flex / E2.1.Micro）。
> 原则：**基于原生 OCI CLI**；**异步判定**（accepted ≠ 成功）；**错误码分类**；**保活自愈**；**不狂刷**（限流是请求级 429，退避脚本自治，但多开脚本=人为放大限流）。

## 1. 部署（一次性）

```bash
mkdir -p ~/oci-arm-catcher && cd ~/oci-arm-catcher
cp <oci-kit>/arm-free-catcher.sh .
cp <oci-kit>/.env.example .env
vim .env                      # 填必填五项（COMPARTMENT_ID/SUBNET_ID/IMAGE_ID/SSH_KEY_FILE/AVAILABILITY_DOMAINS）
./arm-free-catcher.sh --dry-run    # 必须：校验配置+认证+探针+打印将执行命令，退出码 4 为正常
```

## 2. 三种运行模式（按场景选一）

### A. cron 单次模式（推荐，天然自愈+控频）

```bash
crontab -e
# 加一行（flock 防重叠；--once 单轮语义：成功 exit 0 / 无容量 exit 3）：
* * * * * cd ~/oci-arm-catcher && flock -n .lock ./arm-free-catcher.sh --once >> cron.log 2>&1
```

- 每分钟一轮 sweep（全部 AD 各试一次，约 5–15s，远小于间隔）
- 抢到 → exit 0，cron 下分钟再跑会遇 LimitExceeded 正确停止（exit 1）并通知 → **此时手动停 cron**（见 §5）
- 进程死了/机器重启 → cron 自动续命，无需保活进程

### B. systemd 常驻模式

```bash
mkdir -p ~/.config/systemd/user
cp <oci-kit>/arm-free-catcher.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now arm-free-catcher.service
tail -f ~/oci-arm-catcher/catcher.log
```

- 脚本内部两层循环常驻；异常退出 60s 自拉起；**抢到后 exit 0，unit 显示 inactive = 正常终结**
- 适合无人值守但不想动 crontab 的场景

### C. 前台调试模式

```bash
./arm-free-catcher.sh --once --shape VM.Standard.E2.1.Micro --name test-1   # 单轮实测
./arm-free-catcher.sh --no-probe --ad-gap 5 --interval 120                   # 手动调参
```

## 3. 日志判读（catcher.log / cron.log）

| 日志词 | 含义 | 该做什么 |
|---|---|---|
| `探针 XX: AVAILABLE` | 容量报告显示该 AD 有池 | 正常，即将发起 |
| `探针 XX: OUT_OF_HOST_CAPACITY` | 该 AD/shape 无池 | 正常跳过（micro 只有一个 AD 有效是官方约束） |
| `创建请求已受理` | launch accepted（≠成功！） | 等待轮询结果 |
| `SUCCESS! 实例已创建并 RUNNING` | 真成功（已拿公网 IP） | 见 §4 交接 |
| `进入 TERMINATING` | provisioning 被拒（容量窗口关闭） | 正常，自动继续 |
| `触发限流(429)，退避 Ns` | 命中请求级限流 | 自动退避（1→60s 指数），勿干预 |
| `不可重试错误` | LimitExceeded/参数/权限 | 停止有因，看错误信息，见 §6 |

## 4. 抢到后交接（5 分钟）

1. 记录日志里的 OCID + 公网 IP
2. `ssh -i ~/.ssh/id_ed25519 ubuntu@<IP>` 登录验证
3. **清理 TERMINATED 残留**：抢购过程中每个 accepted-but-failed 的实例会留在列表（状态 TERMINATED）。控制台 Compute → Instances 筛选 Terminated 删除，避免计数虚占（很可能是"第 2 台报 limit exceeded"的隐藏因素）
4. 停抢购（§5），按需配保活（Always Free 闲置回收政策：低频心跳/低负载运行即可，工具包不代管）
5. 更新你的实例台账

## 5. 停止

| 模式 | 停止命令 |
|---|---|
| cron | `crontab -e` 注释该行（或 `crontab -l \| grep -v arm-free \| crontab -`） |
| systemd | `systemctl --user stop arm-free-catcher && systemctl --user disable arm-free-catcher` |
| 前台 | Ctrl-C |

## 6. 故障排查

| 症状 | 原因 | 处理 |
|---|---|---|
| `未找到 oci 命令` | PATH | 脚本已自愈 `~/.local/bin`；若用 cron 确认 flock/curl 存在 |
| `认证失败` | ~/.oci/config 无效 | `oci iam region list` 手动验证 |
| 探针 `无响应` | 该 API 对该 shape/AD 不支持（如 flex 缺 config） | 脚本已处理；持续无响应可 `--no-probe` |
| 一直 `不可重试错误` | 额度满/参数错 | A1：2 OCPU+12GB 已满 → 停；micro：one-AD 约束 → 确认 AD 是官方指定那个 |
| 429 频繁 | 多脚本并发/间隔过低 | 只保留一个抢购入口；AD_GAP≥5、RETRY_INTERVAL≥300 |
| 机器重启后失联 | — | cron 模式无此问题；systemd 模式 `loginctl enable-linger $USER` |

## 7. 通知配置（可选）

`.env` 配 `NOTIFY_WEBHOOK` + `NOTIFY_TYPE`：
- **飞书**：机器人 webhook URL，`NOTIFY_TYPE=feishu`
- **Telegram**：`https://api.telegram.org/bot<token>/sendMessage`，`NOTIFY_TYPE=telegram` + `NOTIFY_CHAT_ID`
- **Server 酱**：`https://sctapi.ftqq.com/<sendkey>.send`，`NOTIFY_TYPE=serverchan`
- 通知失败只 warn，不影响抢购

## 8. 设计要点（为什么这样做）

- **两层循环**：内层连续扫全部 AD（容量窗口常只有几十秒），外层 300s±10% 抖动（错峰+避免整点撞限流）
- **异步判定**：CLI launch 默认不等 RUNNING（oci-cli 源码实证）；且 `--wait-for-state RUNNING` 在实例 TERMINATED 时不快速失败、要干等 1200s（源码无该分支）——所以自建轮询（5→10→20s 退避，POLL_TIMEOUT 封顶）
- **`--no-retry`**：OCI SDK 默认对 500/429 等重试约 7 次（社区实测：没货时单次 launch 拖到 ~110s）；禁用后 ~3s 返回失败，节奏控制权归还脚本（deeplabua/oci-arm-catcher issue #1 同结论）
- **错误码优先**：解析响应 `"code"` 字段（OutOfCapacity/TooManyRequests/LimitExceeded…），文本仅兜底；429 单独指数退避不计失败
- **探针**：`compute-capacity-report` 只读预检，筛除明显无池的 AD，减少无效 create（降低限流面）；注意 micro 可能报 AVAILABLE 仍抢不到——探针是筛除判据不是充分判据
- **官方边界**：Always Free 仅 home region；micro 只能在一个 AD 创建；纯免费账户无 Support 工单资格（付费账户有）
