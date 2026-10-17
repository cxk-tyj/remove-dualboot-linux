# remove-dualboot-linux

一个 [WorkBuddy](https://www.codebuddy.cn/) 技能（skill），用于在 **Windows UEFI/GPT 机器上安全删除 Linux（Ubuntu 等）双系统**，而不会把电脑搞成开不了机的 `grub rescue>` 黑屏。

A WorkBuddy skill that safely removes a Linux (Ubuntu) dual-boot from a Windows
UEFI/GPT machine — **without bricking the boot into a `grub rescue>` black screen.**

---

## 为什么需要它 / Why this exists

删除双系统最危险的不是"删分区"，而是**引导顺序**：Linux 安装器要么新增一个
NVRAM 启动项，要么（更阴险地）**直接篡改 Windows 的 `{bootmgr}` 条目的 `path`**
指向它自己的 `shimx64.efi`。如果你在 Windows 还不能独立启动之前就删掉 Linux
分区或它的 EFI 文件夹，机器就死了。

The dangerous part is not deleting the partition; it is the **boot order**.
If you delete the Linux partition (or its EFI folder) before Windows can boot
on its own, the machine drops into an unbootable `grub rescue>`.

本技能的核心原则：**一切破坏性操作，先把只读校验作为前置步骤；任一校验不过
就大声报错并停止，绝不谎报"OK"。**

Core principle: **verification precedes action.** Every destructive step is
gated by a read-only check; any failure stops the script loudly — it never
lies "OK".

---

## 安全流程（顺序不可跳）/ Safe workflow (order is mandatory)

```
[diagnose.ps1]   只读侦察：物理双系统 / WSL / VM？按 GPT GUID 定位 EFI 与
                  Linux 分区？{bootmgr} 是否被劫持？
        │
        ▼
[hand-back-boot.ps1]  备份 EFI\ubuntu → 修复被劫持的 {bootmgr} →
                      删除 GRUB → 清理 NVRAM（可逆向）
        │
        ▼
[重启]  ★ 必过关卡 ★  必须直接进 Windows、GRUB 菜单消失。否则立刻停下。
        │
        ▼
[delete-partition.ps1]  多重校验 + 手输容量 + 手输 DELETE 后才删 Linux 分区
```

### 使用方法 / Usage

所有脚本都通过 **GPT 类型 GUID** 定位分区（绝不靠序号），并带多重校验。

1. **诊断（无需管理员）**
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/diagnose.ps1
   ```
2. **交还引导（需管理员）** —— 双击 `scripts/run-as-admin.bat` 再选本脚本，或：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/hand-back-boot.ps1
   ```
3. **重启**，确认直接进 Windows、无 GRUB 菜单。
4. **删除 Linux 分区（需管理员）**
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/delete-partition.ps1
   ```
   脚本会要求你输入检测到的容量（如 `150`）并手打 `DELETE` 才动手。

---

## 踩过的坑（详见 `references/gotchas.md`）/ Hard-won lessons

1. **diskpart 分区号 ≠ WMI 索引 + 1** —— MSR 保留分区被 `Win32_DiskPartition`
   隐藏，按序号推算会偏移并可能误删 Windows 数据盘。一律用 GUID 定位。
2. **Ubuntu 可能篡改 `{bootmgr}` 而非仅加 NVRAM 项** —— 删 EFI 前必查 `path`
   并用 `bcdboot` 重建。
3. **PowerShell 里 bcdedit 标识符必须加单引号**：`'{bootmgr}'`，否则被当成
   scriptblock 解析失败且静默。
4. **删除分区前必须重启验证** —— 顺序不可跳。
5. **代理（AI 助手）无权限跑 diskpart** —— 交付脚本让用户自提权执行。

---

## 安装到 WorkBuddy / Install into WorkBuddy

把整个目录（含 `SKILL.md`、`scripts/`、`references/`）复制到：

```
C:\Users\<你的用户名>\.workbuddy\skills\remove-dualboot-linux\
```

重启 WorkBuddy 后即可在对话中让助手调用本技能。

Copy the folder into your user-level skills directory, then restart WorkBuddy.

---

## License

[MIT](LICENSE) © 2026 cxk-tyj
