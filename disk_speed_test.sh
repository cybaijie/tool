#!/bin/bash
export LC_ALL=C

TEST_DIR="./DiskBench"
RUNTIME=60
BUFFER_TIME=2
CALIBRATION_FILE="${TEST_DIR}/calibration.data"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'
RESET='\033[0m'

# 测试分组配置
declare -A TEST_GROUPS=(
    ["basic"]="顺序读写 随机读写"
    ["seq"]="顺序写入 顺序读取"
    ["rand"]="随机写入 随机读取"
    ["pt"]="PT下载 PT刷流 PT50% PT上传 PT下载" # 修改：添加 PT上传 和 PT下载
)

# 测试参数映射表
declare -A TEST_MAP=(
    ["seq_rw"]="顺序读写 -seqrw --rw=rw --bs=1M"
    ["rand_rw"]="随机读写 -randrw --rw=randrw --bs=8k --iodepth=1 --numjobs=1"
    ["seq_write"]="顺序写入 -seqwrite --rw=write --bs=1M"
    ["seq_read"]="顺序读取 -seqread --rw=read --bs=1M"
    ["rand_write"]="随机写入 -randwrite --rw=randwrite --bs=8k --iodepth=1 --numjobs=1"
    ["rand_read"]="随机读取 -randread --rw=read --bs=8k --iodepth=1 --numjobs=1"
    ["pt_down"]="PT下载 -ptd --rw=rw --bs=256k --rwmixread=30 --ioengine=sync --direct=0" # 修改：顺序I/O，同步I/O，允许缓存，7写3读
    ["pt_seeding"]="PT刷流 -pts --rw=rw --bs=256k --rwmixread=70 --ioengine=sync --direct=0" # 修改：顺序I/O，同步I/O，允许缓存，7读3写
    ["pt_5050"]="PT50% -pt50 --rw=rw --bs=256k --rwmixread=50 --ioengine=sync --direct=0"  # 修改：顺序I/O，同步I/O，允许缓存，50%读写
    ["pt_upload"]="PT上传 -ptu --rw=read --bs=256k --rwmixread=0 --ioengine=sync --direct=0" # 添加：纯读，模拟上传
    ["pt_download"]="PT下载 -ptdl --rw=write --bs=256k --rwmixread=100 --ioengine=sync --direct=0" # 添加：纯写，模拟下载
)

# 解析命令行参数
selected_tests=()
disk_type=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -disktype)
            disk_type="$2"
            shift 2
            ;;
        -*)
            found=0
            for test_id in "${!TEST_MAP[@]}"; do
                if [[ "${TEST_MAP[$test_id]}" =~ "$1" ]]; then
                    selected_tests+=("$test_id")
                    found=1
                    break
                fi
            done
            if (( found == 0 )); then
                echo -e "${RED}错误: 无效参数 $1${RESET}"
                echo -e "可用参数: ${BOLD}-seqrw -randrw -seqwrite -seqread -randwrite -randread -ptd -pts -pt50 -ptu -ptdl${RESET}"
                exit 1
            fi
            ;;
        *)
            echo -e "${RED}错误: 未知参数 $1${RESET}"
            exit 1
            ;;
    esac
    shift
done

cleanup() {
    echo -e "${YELLOW}⏳ 清理测试环境...${RESET}"
    if [ -d "${TEST_DIR}" ]; then
        rm -rf "${TEST_DIR}"/* 2>/dev/null
        rmdir "${TEST_DIR}" 2>/dev/null
    fi
    echo -e "${GREEN}✅ 清理完成${RESET}"
}

check_deps() {
    local missing=()
    which fio >/dev/null || missing+=("fio")
    which bc >/dev/null || missing+=("bc")
    which jq >/dev/null || missing+=("jq")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}✘ 缺少依赖: ${missing[*]}${RESET}"
        echo -e "${YELLOW}⏳ 尝试自动安装...${RESET}"
        if apt-get update -qq && apt-get install -y -qq "${missing[@]}"; then
            echo -e "${GREEN}✅ 依赖安装成功${RESET}"
        else
            echo -e "${RED}✘ 自动安装失败，请手动执行：sudo apt-get install ${missing[*]}${RESET}" >&2
            exit 1
        fi
    fi
}

prepare_env() {
    mkdir -p "${TEST_DIR}" && chmod 777 "${TEST_DIR}" || {
        echo -e "${RED}✘ 无法创建测试目录${RESET}" >&2
        exit 1
    }

    # 根据磁盘类型设置测试文件大小
    if [[ "$DISK_TYPE" == "HDD" ]]; then
        TEST_FILE_SIZE="512M"
        TEST_CONFIG="512M文件 × 1次测试" # 修改：更新提示信息
    elif [[ "$DISK_TYPE" == "SSD" ]]; then
        TEST_FILE_SIZE="1G"
        TEST_CONFIG="1G文件 × 1次测试" # 修改：更新提示信息
    elif [[ "$DISK_TYPE" == "NVMe" ]]; then
        TEST_FILE_SIZE="4G"
        TEST_CONFIG="4G文件 × 1次测试" # 修改：更新提示信息
    else
        TEST_FILE_SIZE="1G"
        TEST_CONFIG="1G文件 × 1次测试" # 修改：更新提示信息
    fi

    #local required_gb=$(( $(echo "${TEST_FILE_SIZE}" | tr -cd '0-9') * 3 )) # 错误的计算
    local required_mb=$(( $(echo "${TEST_FILE_SIZE}" | tr -cd '0-9') * 1 ))  # 正确的计算，单位为 MB
    local required_gb=$((required_mb / 1024 + 1)) # 转换为 GB，向上取整

    local available_gb=$(df -BG "${TEST_DIR}" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}')
    available_gb=${available_gb:-0}

    echo -e "${BLUE}空间检查报告："
    echo -e "├─ 挂载点: $(df -P "${TEST_DIR}" | awk 'NR==2 {print $6}')"
    echo -e "├─ 需要空间: ${required_gb}G"
    echo -e "└─ 可用空间: ${available_gb}G${RESET}"

    if [ "${available_gb}" -lt "${required_gb}" ]; then
        echo -e "${RED}✘ 错误：可用空间不足，需要至少${required_gb}G${RESET}" >&2
        exit 1
    fi

    # 创建测试文件
    dd if=/dev/zero of="${TEST_DIR}/testfile" bs=$((1024*1024)) count=$(( $(echo "${TEST_FILE_SIZE}" | tr -cd '0-9') )) iflag=fullblock 2>/dev/null || {
        echo -e "${RED}✘ 无法创建测试文件${RESET}" >&2
        exit 1
    }
}

detect_disk_type() {
    echo -e "\n${BLUE}🔍 开始磁盘类型检测...${RESET}"
    rm -f "${CALIBRATION_FILE}" 2>/dev/null

    local output
    if ! output=$(fio --name=calibration \
                    --filename="${CALIBRATION_FILE}" \
                    --rw=write \
                    --bs=1M \
                    --size=1G \
                    --runtime=10 \
                    --time_based \
                    --direct=1 \
                    --ioengine=libaio \
                    --iodepth=64 \
                    --output-format=json 2>&1); then
        echo -e "${RED}✘ 校准测试失败：${output: -120}${RESET}"
        exit 1
    fi

    local bw=$(jq -r '.jobs[0].write.bw | tonumber' <<< "${output}")
    local speed=$(echo "scale=0; ${bw}/1024" | bc)

    echo -e "${GREEN}✅ 实测顺序写入速度: ${speed}MB/s${RESET}"

    if (( speed > 1800 )); then
        echo -e "${BLUE}检测到 NVMe SSD${RESET}"
        echo "NVMe"
    elif (( speed > 450 )); then
        echo -e "${BLUE}检测到 SATA SSD${RESET}"
        echo "SSD"
    elif (( speed > 80 )); then
        echo -e "${BLUE}检测到 HDD${RESET}"
        echo "HDD"
    else
        echo -e "${YELLOW}⚠ 异常低速设备${RESET}"
        echo "UNKNOWN"
    fi
}

run_test() {
    local name=$1
    local desc=$2
    shift 2

    echo -en "${YELLOW}⌛ 测试中: ${desc}...${RESET}"

    declare -A params=(
        ["NVMe-randwrite"]="--iodepth=256 --numjobs=16"
        ["NVMe-pt_down"]="--iodepth=128 --numjobs=8"
        ["NVMe-seeding"]="--iodepth=512 --numjobs=32"
        ["SSD-randwrite"]="--iodepth=64 --numjobs=8"
        ["SSD-pt_down"]="--iodepth=32 --numjobs=4"
        ["SSD-seeding"]="--iodepth=128 --numjobs=16"
        ["HDD-randwrite"]="--iodepth=1 --numjobs=1"
        ["HDD-pt_down"]="--iodepth=2 --numjobs=1"
        ["HDD-seeding"]="--iodepth=8 --numjobs=4"
    )

    local fio_params=(
        "--name=${name}"
        "--filename=${TEST_DIR}/testfile"  # 修改：指定测试文件
        "--size=${TEST_FILE_SIZE}"
        "--runtime=${RUNTIME}"
        "--time_based"
        "--direct=1"
        "--ioengine=sync"  # 修改：使用同步I/O
        "--output-format=json"
        #${params["${DISK_TYPE}-${name}"]} # 注释掉：使用手动指定的参数
        ${params["${disk_type}-${name}"]} # 使用手动指定的参数
        "$@"
    )

    local total_read_iops=0 total_write_iops=0 total_bw=0 total_read_bw=0 total_write_bw=0 success=0
    #for i in {1..3}; do  # 减少测试次数
    for i in {1..1}; do
        if output=$(timeout $((RUNTIME + 30)) fio "${fio_params[@]}" 2>&1); then
            local read_iops=$(jq -r '.jobs[0].read.iops' <<< "${output}")
            local write_iops=$(jq -r '.jobs[0].write.iops' <<< "${output}")
            local bw=$(jq -r '(.jobs[0].read.bw + .jobs[0].write.bw) / 1024 | floor' <<< "${output}")
            local read_bw=$(jq -r '(.jobs[0].read.bw) / 1024 | floor' <<< "${output}")
            local write_bw=$(jq -r '(.jobs[0].write.bw) / 1024 | floor' <<< "${output}")

            total_read_iops=$(echo "${total_read_iops} + ${read_iops}" | bc)
            total_write_iops=$(echo "${total_write_iops} + ${write_iops}" | bc)
            total_bw=$(echo "${total_bw} + ${bw}" | bc)
            total_read_bw=$(echo "${total_read_bw} + ${read_bw}" | bc)
            total_write_bw=$(echo "${total_write_bw} + ${write_bw}" | bc)
            ((success++))
        else
            echo -e "\n${RED}✘ 第${i}次测试失败: ${output: -80}${RESET}"
        fi
        [ $i -lt 1 ] && sleep ${BUFFER_TIME}  # 修改循环条件
    done

    printf "\r\033[K"

    if [[ "$name" == "pt_down" || "$name" == "pt_seeding" || "$name" == "pt_5050" || "$name" == "pt_upload" || "$name" == "pt_download" ]]; then
        local avg_read_iops=$(echo "scale=0; ${total_read_iops} / ${success}" | bc)
        local avg_write_iops=$(echo "scale=0; ${total_write_iops} / ${success}" | bc)
        local avg_iops=$(echo "scale=0; ${avg_read_iops} + ${avg_write_iops}" | bc)
        local avg_bw=$(echo "scale=0; ${total_bw} / ${success}" | bc)
        local avg_read_bw=$(echo "scale=0; ${total_read_bw} / ${success}" | bc)
        local avg_write_bw=$(echo "scale=0; ${total_write_bw} / ${success}" | bc)
        printf "${GREEN}✔ %-15s ${BLUE}IOPS:%'15d ${GREEN}总带宽:%'10dMB/s 上传:%'10dMB/s 下载:%'10dMB/s${RESET}\n" "${desc}" "${avg_iops}" "${avg_bw}" "${avg_read_bw}" "${avg_write_bw}"
    else
        local avg_read_iops=$(echo "scale=0; ${total_read_iops} / ${success}" | bc)
        local avg_write_iops=$(echo "scale=0; ${total_write_iops} / ${success}" | bc)
        local avg_iops=$(echo "scale=0; ${avg_read_iops} + ${avg_write_iops}" | bc)
        local avg_bw=$(echo "scale=0; ${total_bw} / ${success}" | bc)
        printf "${GREEN}✔ %-15s ${BLUE}IOPS:%'15d ${GREEN}总带宽:%'10dMB/s${RESET}\n" "${desc}" "${avg_iops}" "${avg_bw}"
    fi
}

print_separator() {
    echo -e "\n${BLUE}════════ $1 ════════${RESET}"
}

main() {
    trap cleanup EXIT
    check_deps
    prepare_env
    #DISK_TYPE=$(detect_disk_type) # 注释掉：使用手动指定的磁盘类型

    if [ -z "$disk_type" ]; then # 如果没有手动指定磁盘类型，则自动检测
        DISK_TYPE=$(detect_disk_type)
    else
        DISK_TYPE="$disk_type"
    fi

    echo -e "\n${BLUE}════════ 磁盘性能测试 ════════${RESET}"
    echo -e "${GREEN}▧ 磁盘类型: ${YELLOW}${DISK_TYPE}${RESET}"
    echo -e "${GREEN}▧ 测试目录: ${YELLOW}$(realpath "${TEST_DIR}")${RESET}"
    echo -e "${GREEN}▧ 测试配置: ${YELLOW}${TEST_CONFIG}${RESET}" # 修改：使用动态设置的提示信息

    # 如果没有指定参数，默认全选
    ((${#selected_tests[@]} == 0)) && selected_tests=("${!TEST_MAP[@]}")

    # 按分组执行测试
    for group in "basic" "seq" "rand" "pt"; do
        group_tests=()
        for test_id in "${selected_tests[@]}"; do
            [[ "${TEST_GROUPS[$group]}" == *"${TEST_MAP[$test_id]%% *}"* ]] && group_tests+=("$test_id")
        done

        ((${#group_tests[@]} > 0)) || continue

        case $group in
            basic) print_separator "基础性能测试" ;;
            seq)   print_separator "顺序性能测试" ;;
            rand)  print_separator "随机性能测试" ;;
            pt)    print_separator "PT场景测试" ;;
        esac

        for test_id in "${group_tests[@]}"; do
            IFS=' ' read desc short_param params <<< "${TEST_MAP[$test_id]}"
            run_test "${test_id}" "${desc}" ${params}
        done
    done

    echo -e "\n${BLUE}═════════ 测试完成 ═════════${RESET}"
}

main "$@"
