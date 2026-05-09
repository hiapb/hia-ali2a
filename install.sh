#!/usr/bin/env bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_INSTALL_PATH="/opt/aiclient2api"
ENV_RECORD_FILE="/etc/aiclient2api_env"

CRON_TAG_BEGIN="# AICLIENT2API_BACKUP_BEGIN"
CRON_TAG_END="# AICLIENT2API_BACKUP_END"
BACKUP_LOG="/var/log/aiclient2api_backup.log"

CONTAINER_NAME="aiclient2api"
IMAGE_NAME="justlikemaki/aiclient-2-api:latest"

GEMINI_PORT="38085"
ANTIGRAVITY_PORT="38086"
CODEX_PORT="31455"
KIRO_PORT_START="39876"
KIRO_PORT_END="39880"

ADMIN_PASS=""

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1"; }

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "未探测到 Docker Compose 引擎。"
    fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

generate_admin_password() {
    ADMIN_PASS=$(openssl rand -hex 12)
}

write_pwd_file() {
    local workdir="$1"
    mkdir -p "${workdir}/configs"
    echo -n "$ADMIN_PASS" > "${workdir}/configs/pwd"
    chmod 600 "${workdir}/configs/pwd"
}

read_pwd_file() {
    local workdir="$1"
    if [[ -f "${workdir}/configs/pwd" ]]; then
        cat "${workdir}/configs/pwd"
    else
        echo "未能读取"
    fi
}

show_access() {
    local workdir="$1"
    local env_file="${workdir}/.env"

    local host_port
    host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "3000")

    local current_pass
    current_pass=$(read_pwd_file "$workdir")

    echo ""
    echo "=================================================="
    echo -e "\033[32m✅ AIClient2API 实例就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "Web 控制台: \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo "--------------------------------------------------"
    echo -e "后台密码: \033[31m${current_pass}\033[0m"
    echo -e "密码文件: \033[33m${workdir}/configs/pwd\033[0m"
    echo -e "配置目录: \033[33m${workdir}/configs\033[0m"
    echo "--------------------------------------------------"
    echo "端口映射:"
    echo "  Web/API: ${host_port} -> 3000"
    echo "  Gemini OAuth: ${GEMINI_PORT} -> 8085"
    echo "  Antigravity OAuth: ${ANTIGRAVITY_PORT} -> 8086"
    echo "  Codex OAuth: ${CODEX_PORT} -> 1455"
    echo "  Kiro OAuth: ${KIRO_PORT_START}-${KIRO_PORT_END} -> 19876-19880"
    echo "=================================================="
    echo ""
}

wait_app_ready() {
    info "等待 AIClient2API 初始化..."

    for i in {1..60}; do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${CONTAINER_NAME} .*Up"; then
            info "AIClient2API 已启动"
            return 0
        fi
        sleep 2
    done

    warn "AIClient2API 可能未正常启动"
    docker logs --tail=100 "$CONTAINER_NAME" 2>/dev/null || true
    return 1
}

create_compose_file() {
    local workdir="$1"

    cat > "${workdir}/docker-compose.yml" <<EOF
services:
  aiclient2api:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "\${PORT}:3000"
      - "${GEMINI_PORT}:8085"
      - "${ANTIGRAVITY_PORT}:8086"
      - "${CODEX_PORT}:1455"
      - "${KIRO_PORT_START}-${KIRO_PORT_END}:19876-19880"
    volumes:
      - ./configs:/app/configs
    environment:
      - TZ=\${TZ}
EOF
}

deploy_aiclient2api() {
    info "== 启动 AIClient2API 自动化部署编排 =="

    require_cmd docker
    require_cmd curl
    require_cmd tar
    require_cmd awk
    require_cmd openssl

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        err "该路径已存在部署实例或残留数据，请先执行 [8] 卸载。"
        return
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"

    cd "$install_path" || return

    read -r -p "请输入 Web/API 对外访问端口 [默认: 3000]: " input_port
    local host_port=${input_port:-3000}

    valid_port "$host_port" || die "端口不合法，必须是 1-65535"

    mkdir -p configs backups
    chmod -R 777 backups

    generate_admin_password
    write_pwd_file "$install_path"

    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF

    create_compose_file "$install_path"

    info "正在拉取并启动 AIClient2API 容器..."

    $dc_cmd pull || warn "镜像拉取失败，尝试直接启动..."
    $dc_cmd up -d || die "容器启动失败"

    wait_app_ready || true
    show_access "$install_path"
}

upgrade_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到运行中的实例，请先执行 [1] 一键部署。"
        return
    }

    cd "$workdir" || return

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    info "正在拉取最新镜像并重建容器..."

    $dc_cmd pull || die "镜像拉取失败"
    $dc_cmd up -d || die "服务启动失败"

    wait_app_ready || true
    show_access "$workdir"
}

pause_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    cd "$workdir" && $(docker_compose_cmd) stop
    info "服务已停止。"
}

restart_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    cd "$workdir" || return
    $(docker_compose_cmd) restart
    wait_app_ready || true
    show_access "$workdir"
}

reset_admin_password() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    generate_admin_password
    write_pwd_file "$workdir"

    cd "$workdir" || return
    $(docker_compose_cmd) restart "$CONTAINER_NAME" >/dev/null 2>&1 || true

    info "后台密码已重置。"
    show_access "$workdir"
}

do_backup() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    local temp_dir="${backup_dir}/tmp_${timestamp}"
    mkdir -p "$temp_dir"

    cp "${workdir}/docker-compose.yml" "${temp_dir}/" 2>/dev/null || true
    cp "${workdir}/.env" "${temp_dir}/" 2>/dev/null || true
    [[ -d "${workdir}/configs" ]] && cp -r "${workdir}/configs" "${temp_dir}/configs"

    local backup_file="${backup_dir}/aiclient2api_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" -C "$temp_dir" .
    rm -rf "$temp_dir"

    cd "$backup_dir" || return
    ls -t aiclient2api_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

restore_backup() {
    local workdir
    workdir=$(get_workdir)

    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup
    default_backup=$(ls -t "${search_dir}"/aiclient2api_backup_*.tar.gz 2>/dev/null | head -n 1 || true)

    read -r -p "请输入备份文件路径 [直接回车使用默认: ${default_backup}]: " backup_path
    local path=${backup_path:-$default_backup}

    [[ ! -f "$path" ]] && {
        err "未找到有效的快照文件。"
        return
    }

    local safe_backup="/tmp/$(basename "$path")"
    cp "$path" "$safe_backup" || die "备份文件复制到临时目录失败"

    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd=${target_dir:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$wd" ]]; then
        read -r -p "目标目录已存在实例，是否强制覆盖？(y/N): " confirm

        [[ ! "$confirm" =~ ^[Yy]$ ]] && {
            rm -f "$safe_backup"
            return
        }

        cd "$wd" 2>/dev/null && $(docker_compose_cmd) down 2>/dev/null || true
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        cd /
        rm -rf "$wd"
    fi

    mkdir -p "$wd"
    tar -xzf "$safe_backup" -C "$wd" || die "解压备份失败"

    mkdir -p "${wd}/backups"
    cp "$safe_backup" "${wd}/backups/$(basename "$safe_backup")" 2>/dev/null || true
    rm -f "$safe_backup"

    echo "$wd" > "$ENV_RECORD_FILE"

    cd "$wd" || return

    mkdir -p configs backups
    chmod -R 777 backups 2>/dev/null || true

    [[ ! -f "${wd}/docker-compose.yml" ]] && create_compose_file "$wd"

    if [[ ! -f "${wd}/.env" ]]; then
        cat > "${wd}/.env" <<EOF
PORT=3000
TZ=Asia/Shanghai
EOF
    fi

    if [[ ! -f "${wd}/configs/pwd" ]]; then
        generate_admin_password
        write_pwd_file "$wd"
    fi

    $(docker_compose_cmd) up -d || die "容器启动失败"

    wait_app_ready || true
    show_access "$wd"
}

setup_auto_backup() {
    require_cmd crontab

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    local cron_script="${workdir}/cron_backup.sh"
    local script_path
    script_path="$(readlink -f "${BASH_SOURCE[0]}")"

    echo " 1) 按固定分钟步进备份（推荐：10/15/20/30/60）"
    echo " 2) 按每日固定时间点备份（例如：每天 04:30）"
    echo " 3) 删除当前的定时备份任务"

    read -r -p "请选择策略 [1/2/3]: " cron_type

    local cron_spec=""

    case "$cron_type" in
        1)
            read -r -p "请输入间隔分钟数: " min_interval
            [[ "$min_interval" =~ ^[0-9]+$ ]] || {
                err "分钟数无效"
                return
            }
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]] || {
                err "时间格式无效"
                return
            }
            cron_spec="${minute} ${hour} * * *"
        ;;
        3)
            crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true
            rm -f "$cron_script"
            info "定时任务已注销。"
            return
        ;;
        *)
            err "无效选择"
            return
        ;;
    esac

    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
bash "$script_path" run-backup >> "$BACKUP_LOG" 2>&1
EOF

    chmod +x "$cron_script"

    (
        crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"
        echo "$CRON_TAG_BEGIN"
        echo "${cron_spec} bash ${cron_script}"
        echo "$CRON_TAG_END"
    ) | crontab -

    info "新的定时任务已注入。"
}

clean_all_aiclient2api() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker network rm aiclient2api_default 2>/dev/null || true
}

uninstall_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && workdir=$DEFAULT_INSTALL_PATH

    echo -e "\033[31m⚠️ 警告：这将彻底删除容器和本地配置数据！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if [[ -d "$workdir" ]]; then
        cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down 2>/dev/null || true
    fi

    clean_all_aiclient2api

    cd /
    rm -rf "$workdir"
    rm -f "$ENV_RECORD_FILE"

    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true

    info "容器及配置数据已被清理。"
}

install_ftp() {
    clear
    echo -e "\033[32m📂 FTP/SFTP 备份工具...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

main_menu() {
    clear
    echo "==================================================="
    echo "                AIClient2API 一键管理              "
    echo "==================================================="
    local wd
    wd=$(get_workdir)
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 📂 FTP/SFTP 备份工具"
    echo " 10) 重置后台密码"
    echo "  0) 退出脚本"
    echo "==================================================="
    read -r -p "请输入操作序号 [0-10]: " choice

    case "$choice" in
        1) deploy_aiclient2api ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        10) reset_admin_password ;;
        0) info "欢迎下次使用，再见!"; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then
        die "权限收敛：必须使用 Root 权限执行脚本。"
    fi

    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
