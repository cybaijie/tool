#!/bin/bash

# 函数：显示硬盘列表并让用户选择
select_disk() {
  local disks=($(ls /dev/disk/by-id/ | grep "scsi-0BUYVM_SLAB_VOLUME"))
  local mounted_disks=()
  local unmounted_disks=()
  local mount_points=()

  if [ ${#disks[@]} -eq 0 ]; then
    echo "未找到任何 BUYVM SLAB 硬盘。" >&2
    exit 1
  fi

  # 区分已挂载和未挂载的硬盘，并获取挂载点
  echo "===== 硬盘挂载状态 =====" >&2
  for disk in "${disks[@]}"; do
    local disk_path="/dev/disk/by-id/$disk"
    local real_device=$(readlink -f "$disk_path")
    local mount_point=$(mount | awk -v dev="$real_device" '$1 == dev {print $3}')
    
    if [ -n "$mount_point" ]; then
      mounted_disks+=("$disk")
      mount_points+=("$mount_point")
      echo "$disk: 已挂载 (挂载点: $mount_point)" >&2
    else
      unmounted_disks+=("$disk")
      echo "$disk: 未挂载" >&2
    fi
  done
  echo "========================" >&2

  # 验证已挂载硬盘选择
  if [ ${#mounted_disks[@]} -gt 0 ]; then
    echo "已挂载的硬盘：" >&2
    for i in "${!mounted_disks[@]}"; do
      echo "$((i+1))) ${mounted_disks[$i]} (挂载点: ${mount_points[$i]})" >&2
    done

    while true; do
      read -r -p "请选择要替换的已挂载硬盘的编号: " mounted_choice
      if [[ "$mounted_choice" =~ ^[0-9]+$ ]] && [ "$mounted_choice" -ge 1 ] && [ "$mounted_choice" -le ${#mounted_disks[@]} ]; then
        selected_mounted_disk="${mounted_disks[$((mounted_choice-1))]}"
        selected_mount_point="${mount_points[$((mounted_choice-1))]}"
        break
      else
        echo "无效的输入，请输入 1-${#mounted_disks[@]} 之间的数字。" >&2
      fi
    done
  else
    echo "没有已挂载的 BUYVM SLAB 硬盘。" >&2
    exit 1
  fi

  # 验证未挂载硬盘选择
  if [ ${#unmounted_disks[@]} -gt 0 ]; then
    echo "未挂载的硬盘：" >&2
    for i in "${!unmounted_disks[@]}"; do
      echo "$((i+1))) ${unmounted_disks[$i]}" >&2
    done

    while true; do
      read -r -p "请选择用于替换的未挂载硬盘的编号: " unmounted_choice
      if [[ "$unmounted_choice" =~ ^[0-9]+$ ]] && [ "$unmounted_choice" -ge 1 ] && [ "$unmounted_choice" -le ${#unmounted_disks[@]} ]; then
        selected_unmounted_disk="${unmounted_disks[$((unmounted_choice-1))]}"
        break
      else
        echo "无效的输入，请输入 1-${#unmounted_disks[@]} 之间的数字。" >&2
      fi
    done
  else
    echo "没有未挂载的 BUYVM SLAB 硬盘。" >&2
    exit 1
  fi

  echo "操作确认：" >&2
  echo "要替换的已挂载硬盘: $selected_mounted_disk (挂载点: $selected_mount_point)" >&2
  echo "用于替换的未挂载硬盘: $selected_unmounted_disk" >&2
  read -r -p "是否确认继续操作？(y/n) " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "操作已取消。" >&2
    exit 0
  fi

  echo "$selected_mounted_disk|$selected_unmounted_disk|$selected_mount_point"
}

# 函数：卸载硬盘（修复语法错误）
umount_disk() {
  local mount_point="$1"
  echo "正在卸载 ${mount_point}..." >&2

  # 首次尝试卸载
  if umount "$mount_point" 2>/dev/null; then
    echo "卸载成功" >&2
    return 0
  fi

  # 处理设备忙的情况
  echo "检测到挂载点被占用，尝试终止相关进程..." >&2
  killall -9 qbittorrent-nox 2>/dev/null
  sleep 2

  # 再次尝试卸载
  if umount "$mount_point"; then
    echo "卸载成功" >&2
    return 0
  else
    echo "再次卸载失败，可能仍有进程占用" >&2
    ps aux | grep -ie "qbittorrent\|$mount_point"
    exit 1
  fi
}  # 修复：添加闭合大括号

# 函数：格式化硬盘
format_disk() {
  local disk_path="$1"
  echo "警告：这将永久清除 $disk_path 上的所有数据！" >&2
  while true; do
    read -r -p "是否确认格式化硬盘 ${disk_path}？(y/n) " yn
    case $yn in
      [Yy]* )
        echo "正在格式化 ${disk_path}..." >&2
        if mkfs.ext4 -F "$disk_path"; then
          echo "格式化成功" >&2
          break
        else
          echo "格式化失败" >&2
          exit 1
        fi
        ;;
      [Nn]* )
        echo "跳过格式化操作" >&2
        break
        ;;
      * )
        echo "请输入 y 或 n" >&2
        ;;
    esac
  done
}

# 函数：挂载硬盘
mount_disk() {
  local disk_path="$1"
  local mount_point="$2"

  echo "正在创建挂载点目录..." >&2
  if [ ! -d "$mount_point" ]; then
    mkdir -p "$mount_point" || {
      echo "无法创建挂载点目录" >&2
      exit 1
    }
  fi

  echo "正在挂载 ${disk_path} 到 ${mount_point}..." >&2
  if mount -o discard,defaults "$disk_path" "$mount_point"; then
    echo "挂载成功" >&2
  else
    echo "挂载失败，请检查错误信息" >&2
    exit 1
  fi
}

# 修正后的fstab设置函数
set_fstab() {
  local old_disk_path="$1"
  local new_disk_path="$2"
  local mount_point="$3"

  echo "正在备份/etc/fstab..." >&2
  cp /etc/fstab /etc/fstab.bak || exit 1

  echo "删除旧条目：$old_disk_path" >&2
  sed -i "\|^${old_disk_path}[[:space:]]\+${mount_point}[[:space:]]|d" /etc/fstab

  echo "添加新条目：$new_disk_path" >&2
  sed -i "\|^${new_disk_path}[[:space:]]\+${mount_point}[[:space:]]|d" /etc/fstab
  echo "${new_disk_path} ${mount_point} ext4 defaults,nofail,discard 0 0" >> /etc/fstab

  echo "验证fstab变化：" >&2
  diff -U0 /etc/fstab.bak /etc/fstab | grep -v ^@@
}

# 主程序
echo "===== BUYVM 硬盘替换脚本 =====" >&2
echo "版本：1.4.1" >&2
echo "更新说明：" >&2
echo "- 修复函数语法错误" >&2
echo "- 优化fstab更新逻辑" >&2
echo "=============================" >&2

# 获取选择信息
selected_info=$(select_disk)
IFS='|' read -r old_disk new_disk mount_point <<< "$selected_info"

# 转换设备路径
old_disk_path="/dev/disk/by-id/${old_disk}"
new_disk_path="/dev/disk/by-id/${new_disk}"

# 执行操作流程
umount_disk "$mount_point"
format_disk "$new_disk_path"
mount_disk "$new_disk_path" "$mount_point"
set_fstab "$old_disk_path" "$new_disk_path" "$mount_point"

# 设置权限
echo "正在设置目录权限..." >&2
chmod -R 777 "$mount_point"

# 完成验证
echo "操作完成，最终状态：" >&2
echo "1. 挂载信息：" >&2
df -hT "$mount_point" >&2
echo "2. fstab最新条目：" >&2
grep "BUYVM_SLAB_VOLUME" /etc/fstab >&2
echo "=============================" >&2
