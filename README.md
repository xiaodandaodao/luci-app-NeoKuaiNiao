# luci-app-NeoKuaiNiao

迅雷快鸟宽带提速的 LuCI 插件（OpenWrt / QWRT）。两种取凭证方式：

- **仓库**：[github.com/xiaodandaodao/luci-app-NeoKuaiNiao](https://github.com/xiaodandaodao/luci-app-NeoKuaiNiao)
- **License**：MIT
- **维护者**：xiaodandaodao
- **当前版本**：1.2.2（QWRT / OpenWrt 21.02+ 实装验证，`PKGARCH:=all` 纯脚本包）
- **依赖**：`luci-base` `rpcd` `uclient-fetch` `openssl-util`；不硬绑 curl

1. **页面内直接登录**（推荐）：在 LuCI 里输账号密码，服务端要求图形验证码时页面显示图片，输 4 个字符即可完成登录；
2. **凭证导入**：在电脑上跑 `kp-login.sh` 拿到 `loginKey`，把内容粘进页面。

两种方式最终都只保存 `loginKey` / `userID` / `peerID` / `devicesign`，日常靠 `/loginkey` 静默续期，
不再需要密码与验证码。**密码只经内存（tmpfs），登录成功/取消/10 分钟超时立即删除，不写 flash。**

> 前提：你本人已购买快鸟 / 超级会员权益，且该线路官方客户端可提速。
> 本项目**不提供也不得用于**绕过付费权益、共享账号或免会员提速。

## 它做什么

控制面闭环，不碰数据面（提速是运营商侧改带宽模板）：

```
探测 portal → 查带宽(can_upgrade) → 按需 upgrade → 定时 keepalive → 掉速/会话失效自动重试
```

- 常驻由 `procd` 托管，开机自启，异常自动拉起
- 停止服务时主动 `recover` 恢复带宽，避免占着提速额度
- 请求优先走 WAN 出口（可选绑定接口），避免代理/旁路由导致服务端判「宽带不支持」
- 不硬绑 curl：QWRT 自带 curl 可能与 libcurl 不匹配（`Error relocating`），
  HTTP 走 `wget`/`nc`/`uclient-fetch`，HTTPS 走 `openssl s_client`

### 心跳与时序（1.2.0 起，据路由器日志 + 参考实现 swjsq.py 修正）

服务端把 `upgrade` 与 `keepalive` 视为**同一类「点击」请求**，最小间隔约 120 秒
（被限流时响应里明示 `button_data.can_click_time=120`）。因此：

1. **本轮只要点过 upgrade（errno=0/812 成功、2204 失败都算——实测失败同样点亮
   点击窗口），就不再发心跳**——0 秒后发必被 711 拒，保活白发；加速到期后反被
   513 判掉速，陷入「重提 → 711 → 掉速」死循环（1.1.9 及之前的实测症状）；
   保活留给下一轮（间隔 ≥300 秒，必过窗口）；
2. 重新点击的条件：`BOOST_OK` 未确认 / 心跳判掉速（513、824）/ 距上次成功提速超过
   3 小时兜底；且距上次点击已过 130 秒（CLI 手动调用同样受此保护）；
3. 711 限流不计失败（服务端承诺"稍后快鸟将自动为您重新提速"）；守护进程等过点击
   窗口（约 130 秒）就重试，连续 3 次仍被限流退回 300 秒——重启时 prerm 的 recover
   会点亮点击窗口，首轮 upgrade 必被 711，靠这个分支在 2 分钟内恢复提速；
   513/824 掉速（提速通道被服务端关掉）走**快速重提**：等过点击窗口（130 秒）
   立即重新下发 upgrade（1.2.2 起；此前同样 300 秒），连续 3 次仍未成功才退回
   300 秒；2204 等瞬时错误仍 300 秒后重试。参考实现 `swjsq.py` 也是把掉速当常态
   兜底（590 秒一轮只发 keepalive、每 ~3 小时才 upgrade 且先 `recover` + 等 20 秒）。
   掉速瞬间刚发的那次心跳/升级本身已点亮 120 秒限流窗口，窗口内立刻重发只会换
   711——130 秒是「检测到 513 就直接重试」的物理下限。

## 页面内登录（含图形验证码）

```
账号密码 → POST /login（预期 errorCode=6，服务端下发设备 cookie）
        → 用同一 cookie 取验证码图（拿到 VERIFY_KEY）
        → 带着 verifyKey + verifyCode 再 POST /login → errorCode=0，得到 sessionID + loginKey
```

- 验证码图片由路由器下载后转 base64 交给浏览器显示（img width 280px），**不是**让浏览器直连迅雷
- 输错会自动换一张图，最多不限次数（页面可点「换一张」）
- 密码经 `fs.write` 写入 `/var/run/neokuainiao/login.pw`（0600）→ 脚本读入后立刻删除原文件，
  再转存到 `/var/run/neokuainiao/login/`（0700）供第二次提交使用；成功/取消/超时整目录删除
- `peerID` 取默认出口网卡 MAC + `004V`；`devicesign` 由密码派生
  （`div101.` + md5(sha1(md5("msfdc"+密码+"23333") + pkg + 68 + salt))），与官方客户端一致

> 取验证码需要能读到响应头里的 `Set-Cookie`，因此 HTTP 客户端必须是 `curl` / `wget` / `nc` 之一。
> 若系统里只有 `uclient-fetch`（不输出响应头），页面会提示：`opkg install wget`。

## 组成

| 路径 | 说明 |
|---|---|
| `root/usr/libexec/neokuainiao/kpn.sh` | 核心：登录 + 协议实现 + 守护循环 |
| `root/etc/init.d/neokuainiao` | procd 服务（stop 时 recover + 清登录会话） |
| `root/etc/config/neokuainiao` | UCI 配置（`enabled` / `interval` / `iface`） |
| `root/usr/share/luci/menu.d/` | 菜单项（服务 → 迅雷快鸟提速） |
| `root/usr/share/rpcd/acl.d/` | 权限（仅限本包脚本、凭证文件、`/var/run/neokuainiao/*`） |
| `htdocs/.../view/neokuainiao/overview.js` | LuCI 页面（状态 / 登录 / 凭证导入 / 设置） |
| `tools/build_ipk.py` | macOS/Linux 本地打 ipk（无需 SDK） |

## 安装

```bash
# 装包（QWRT 是 opkg；dropbear 无 sftp，别用 scp，走管道）
cat luci-app-NeoKuaiNiao/dist/luci-app-neokuainiao_1.2.2-1_all.ipk \
  | ssh root@192.168.1.1 'cat > /tmp/kpn.ipk'
ssh root@192.168.1.1 'opkg install /tmp/kpn.ipk'
```

LuCI 里「系统 → 软件包 → 上传软件包」也可以，上传后会落在 `/tmp/upload.ipk` 并自动执行安装。

### 兜底：opkg 报 `Malformed package file`

`pkg_init_from_file: Malformed package file` 只有一个常见原因：**打包容器格式选错**。

OpenWrt/QWRT 的 `.ipk` **不是** Debian 的 ar 容器（`!<arch>` + 三成员），而是
**一个 gzip 压缩的 tar**，tar 内放三个文件，顺序是：

```
./debian-binary    内容就是 "2.0\n"
./data.tar.gz
./control.tar.gz
```

注意 `data.tar.gz` 在 `control.tar.gz` **之前**，与 `.deb` 的 ar 顺序相反。
`tools/build_ipk.py` 的 `ipk_write()` 已按此实现，并在 `ipk_verify()` 里自检：
gzip 魔数、成员名与顺序、`debian-binary` 内容、以及 postinst/prerm 的 shell 语法。

自检方法：

```bash
file dist/luci-app-neokuainiao_1.2.2-1_all.ipk   # 应显示 gzip compressed data
tar tzf dist/luci-app-neokuainiao_1.1.9-1_all.ipk
#   ./debian-binary
#   ./data.tar.gz
#   ./control.tar.gz
```

若仍要绕开 opkg，可用随包附送的负载包安装（不写 opkg 数据库，卸载需手工删文件）：

```bash
cat luci-app-NeoKuaiNiao/dist/luci-app-neokuainiao-payload_1.2.2-1.tar.gz \
  | ssh root@192.168.1.1 'cat > /tmp/kpn.tar.gz'
ssh root@192.168.1.1 'tar xzf /tmp/kpn.tar.gz -C / \
  && /etc/init.d/neokuainiao enable \
  && /etc/init.d/neokuainiao restart \
  && rm -f /tmp/luci-indexcache* && rm -rf /tmp/luci-modulecache \
  && killall -HUP rpcd'
```

> 历史坑：1.1.0/1.1.1 的 postinst/prerm 模板里 `{{IPKG_INSTROOT}}` 的双大括号
> 没有经过 `.format()` 还原，原样写进 shell 导致 `bad substitution`。
> 升级时 opkg 会先跑**旧版**残留在 `/usr/lib/opkg/info/` 的 prerm，脚本坏就会
> 中断升级、把包留在半删除状态。修复：手动 `sed -i 's/{{/{/g; s/}}/}/g'`
> 那两个文件后再 `opkg install`。1.1.4 起构建时会用 `sh -n` 自检，不会再出现。

手工卸载（办法二装的）：

```bash
ssh root@192.168.1.1 '/etc/init.d/neokuainiao stop; /etc/init.d/neokuainiao disable
rm -f /etc/init.d/neokuainiao /etc/config/neokuainiao /usr/sbin/neokuainiao
rm -rf /usr/libexec/neokuainiao /usr/share/luci/menu.d/luci-app-neokuainiao.json \
       /usr/share/rpcd/acl.d/luci-app-neokuainiao.json \
       /www/luci-static/resources/view/neokuainiao /etc/neokuainiao'
```

然后打开 **LuCI → 服务 → 迅雷快鸟提速**：

1. 在「账号密码登录」里填账号密码 → **获取验证码** → 按图输入 4 个字符 → **提交验证码**；
2. 登录成功后插件会自动写入凭证、勾上「启用」并立刻跑一轮提速；
3. 页面顶部能看到「当前下行 / 上限」，点「立即提速」可手动重发。

### 备用：凭证导入

```bash
# 电脑上（与路由器同一出口 IP），进入 kp-login.sh 所在目录后：
./kp-login.sh auto          # 按提示输入账号密码与图形验证码
cat /tmp/kp-state.env       # 把输出整段粘到页面「凭证导入」里保存
```

## 命令行

```bash
neokuainiao status                 # 查带宽（当前 / 上限）
neokuainiao up | down              # 下发提速 / 恢复带宽
neokuainiao renew                  # 用 loginKey 静默续期 sessionID
neokuainiao run-once               # 一轮完整流程：探测 → 提速 → 心跳
neokuainiao state                  # 打印状态 JSON

# 登录（密码用文件传，不进 argv）
printf '%s' 'PASSWORD' > /var/run/neokuainiao/login.pw && chmod 600 /var/run/neokuainiao/login.pw
neokuainiao login-prepare <账号>    # 输出 STAGE=captcha + IMAGE_B64=...
neokuainiao login-submit <验证码>   # 成功输出 STAGE=ok / USERID=...
neokuainiao login-refresh           # 换一张
neokuainiao login-cancel            # 清掉临时会话（含临时密码）
```

## 配置项

| UCI | 默认 | 说明 |
|---|---|---|
| `enabled` | `0` | 开启常驻（页面登录成功会自动置 1） |
| `interval` | `300` | 轮询间隔（秒），即两轮「查带宽 → 心跳」之间的等待；服务端对提速/心跳有约 120 秒最小点击间隔（响应里 `can_click_time=120`），提完速的当轮会自动跳过心跳，失败按 300 秒重试。建议 300~900，最低 120 |
| `iface` | 空 | 出口接口名（如 `pppoe-wan`），仅 curl 可用时生效 |

> ⚠️ **QWRT 的 uci 不支持省略 section 名的简写**：`uci get neokuainiao.enabled` 会直接
> 失败（rc=1），必须写全 `neokuainiao.<section>.enabled`。且 `uci get <cfg>.@<type>[0]`
> 返回的是 **type 而非 section 名**，不可用于定位。脚本里 `_cfg_section()` 是遍历
> `uci show` 的 section、取第一个带 `enabled` 选项的，故 section 叫 `main` 还是 `config`
> 都能工作。前端 `uci.set('neokuainiao','main',...)` 仍写死 `main`，改默认段名前先同步这里。

## 协议 errno 速查

| errno | message | 性质 | 处理 |
|---|---|---|---|
| `0` | — | 成功 | 正常 |
| `812` | `speedup server already speed up` | **成功**（服务器记录该线路已在提速中） | 视为已提速，本会话后续轮次跳过重复下发（`BOOST_OK`），距上次提速超过 3 小时才兜底确认一次 |
| `711` | `client request too frequent` | **限流**，非故障；服务端承诺"稍后快鸟将自动为您重新提速" | 不计失败；守护进程等过点击窗口（约 130 秒）重试，连续 3 次仍被限流则退回 300 秒节奏 |
| `513` / `824` | speedup closed | **掉速**（服务端已关闭提速） | 清 `BOOST_OK`，下一轮重新下发提速 |
| `2204` | `启用提速失败#` | 服务端瞬时错误 | 计入失败、300 秒后重试；本轮不再发心跳（刚点过，发了也被 711 拒） |
| `715` / `717` / `718` | session 失效 | 需续期 | 自动 `_renew_session` 后重试 |
| `6` | 需要图形验证码 | 登录阶段 | 页面取图，输入 4 个字符 |
| 其他 | — | 真失败 | `state=up_fail` / `keepalive_fail`，计入失败计数 |

> 曾把 `711` 误判成"已提速"、把 `812` 当成报错，都是因为**没查 message 字段**。
> 排查任何 errno 先用 `KPN_VERBOSE=1 neokuainiao up 2>&1 | grep raw:` 看原始响应。

> ⚠️ `CUR_DOWN="$MAX_DOWN"` 是乐观假设：`bandwidth` 接口的 `downstream` 不实时反映
> 运营商侧改动，提速下发后它可能仍返回旧值。判断是否真提速请以**实测网速**为准，
> 不要只看页面数字。

## 状态文件

`/var/run/neokuainiao/status.json` —— LuCI 页面读它渲染：

```json
{"ts":...,"state":"running","cur_down":512000,"max_down":512000,
 "up_cur":40960,"up_supported":0,"errno":"","msg":"",
 "province":"江苏","sp":"电信","dial":"2-...","userid":"...","has_session":"1","last_up":...,"boost_ok":...}
```

带宽单位 **Kbps**（`204800` = 200 Mbps）。

`last_up`（最近一次点击类请求的时间戳）和 `boost_ok`（是否已确认在提速状态）会被
下一次 CLI 调用继承——手动 `run-once`/`up` 是新进程，不继承就会在服务端已提速的
状态下重复点击 upgrade（1.2.1 修复；`boost_ok` 仅当上一轮 `state=running` 时才继承，
心跳刚失败说明提速状态可能已丢，必须重新点击）。

`state` 取值：`running` / `up` / `down` / `disabled` / `no_cred` / `no_upgrade` / `up_fail` / `keepalive_fail`。

## 自建包

```bash
python3 tools/build_ipk.py           # 输出 dist/luci-app-neokuainiao_<ver>-<rel>_all.ipk
```

打包规则对齐 `feeds/luci/luci.mk`：`root/* → /`、`htdocs/* → /www/`，
`/etc/init.d/*`、`/usr/libexec/*.sh`、`/usr/sbin/*` 保持 0755，其余 0644，属主 root:root。

## 排查

| 现象 | 处理 |
|---|---|
| 取验证码失败，日志提示只有 uclient-fetch | `opkg install wget`（需要能读 `Set-Cookie` 的客户端） |
| 登录 `errorCode=3` | 账号或密码错；注意输入法别把 `! ( *` 打成全角 |
| 登录 `errorCode=13` | peerID / devicesign / 密码 之一不对（改了密码需重新登录） |
| 登录 `errorCode=6` 反复 | 验证码识别错，点「换一张」再试；每题自动换图 |
| 登录 `errorCode=724` | 账号被风控，停手 2 小时以上，或先用手机迅雷 APP 正常登录一次 |
| 页面状态一直是「未导入凭证」 | `cred.env` 是否存在、是否含 `KP_USERID`/`KP_PEERID` |
| `state=no_upgrade` | 线路被判不可提速，或被代理改了源 IP；检查 `iface` 与分流 |
| `errno=715/717/718` | sessionID 过期，插件自动用 loginKey 续期；持续失败需重新登录 |
| 心跳总是 `errno=711`（请求太频繁） | 间隔低于服务端下限（约 120s），或刚提完速就当轮发心跳（1.2.0 起已自动避开）；若仍频繁，检查是否开着多个页面/脚本在手动触发 |
| 提速后过几分钟回落 | 看日志确认心跳是否返回 0；`errno=513` 即服务端关提速（运营商侧会话时效，无法根治），插件自动重新下发——1.2.2 起约 2 分钟内恢复，仍频繁掉速时重新登录换 sessionID 试试 |
