#!/bin/bash

# Kubernetes集群优雅关机脚本（在master01上执行）
# 增强版：处理无法驱逐的Pod情况

# 定义节点列表
WORKER_NODES=("work01" "work02" "work03")
MASTER_NODES=("master01" "master02" "master03")

# 配置参数
MAX_EVICT_RETRY=1               # 最大驱逐重试次数
FORCE_SHUTDOWN_TIMEOUT=3      # 强制关机前的等待时间(秒)
DRAIN_TIMEOUT=3               # drain操作的超时时间

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 检查节点是否可访问
check_node_accessible() {
    if ! ssh $1 "echo Connected" &>/dev/null; then
        log "警告: 节点 $1 已经不可访问"
        return 1
    fi
    return 0
}

# 尝试优雅驱逐节点上的Pod
graceful_drain_node() {
    local node=$1
    local retry=0
    
    while [ $retry -lt $MAX_EVICT_RETRY ]; do
        log "尝试驱逐节点 $node 上的Pod (尝试 $((retry+1))/$MAX_EVICT_RETRY)..."
        
        # 使用--disable-eviction参数避免PDB限制
        drain_output=$(sudo kubectl drain $node \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --force \
            --timeout=${DRAIN_TIMEOUT}s \
            --grace-period=60 2>&1)
        
        if [ $? -eq 0 ]; then
            log "节点 $node 上的Pod已成功驱逐"
            return 0
        fi
        
        # 检查是否有PDB限制的错误
        if echo "$drain_output" | grep -q "Cannot evict pod as it would violate the pod's disruption budget"; then
            log "警告: 部分Pod因PDB限制无法驱逐"
            log "将尝试强制驱逐..."
            
            # 获取无法驱逐的Pod列表
            blocked_pods=$(echo "$drain_output" | grep -oP "pods/\"\K[^\"]+" | tr '\n' ' ')
            log "无法驱逐的Pod: $blocked_pods"
            
            # 尝试删除PDB限制（谨慎操作）
            for pod in $blocked_pods; do
                ns=$(echo "$pod" | awk -F'/' '{print $1}')
                pod_name=$(echo "$pod" | awk -F'/' '{print $2}')
                log "临时删除PDB限制: $pod"
                sudo kubectl delete pdb --all-namespaces --selector app=${pod_name} || true
            done
        fi
        
        retry=$((retry+1))
        sleep 10
    done
    
    log "错误: 无法完全驱逐节点 $node 上的Pod"
    return 1
}

# 优雅关闭节点函数
graceful_shutdown_node() {
    local node=$1
    log "开始优雅关闭节点: $node"
    
    # 检查节点是否可访问
    if ! check_node_accessible $node; then
        return
    fi
    
    # 1. 如果是worker节点，执行驱逐
    if [[ " ${WORKER_NODES[@]} " =~ " ${node} " ]]; then
        if ! graceful_drain_node $node; then
            log "警告: 继续关闭节点 $node 尽管有Pod未被完全驱逐"
        fi
    fi
    
    # 2. 停止kubelet服务
    log "正在停止节点 $node 上的kubelet服务..."
    ssh $node "sudo systemctl stop kubelet"
    
    # 3. 停止容器运行时（根据实际运行时调整）
    log "正在停止节点 $node 上的容器运行时..."
    ssh $node "sudo systemctl stop containerd || sudo systemctl stop docker"
    
    # 4. 正常关机
    log "正在关闭节点 $node ..."
    ssh $node "sudo shutdown -h now"
    
    log "节点 $node 关机指令已发送"
}

# 主执行流程
log "开始Kubernetes集群优雅关机流程"

# 首先关闭所有worker节点
log "开始关闭worker节点..."
for worker in "${WORKER_NODES[@]}"; do
    graceful_shutdown_node $worker
done

# 等待所有worker节点关闭
log "等待worker节点关闭(${FORCE_SHUTDOWN_TIMEOUT}秒)..."
sleep $FORCE_SHUTDOWN_TIMEOUT

# 然后关闭其他master节点（master01最后关闭）
log "开始关闭其他master节点..."
for master in "${MASTER_NODES[@]}"; do
    if [ "$master" != "$HOSTNAME" ]; then
        graceful_shutdown_node $master
    fi
done

# 最后关闭当前节点(master01)
log "开始关闭当前节点(master01)..."
log "正在停止kubelet服务..."
sudo systemctl stop kubelet
log "正在停止容器运行时..."
sudo systemctl stop containerd || sudo systemctl stop docker
log "正在关闭当前节点..."
sudo shutdown -h now

cat <<EOF

==================================================
[!] 重要提示：集群重启后请执行以下操作 [!]

1. 恢复worker节点调度能力：
   for node in work01 work02 work03; do
     kubectl uncordon \$node
   done

2. 检查所有节点状态：
   kubectl get nodes -o wide

3. 检查所有Pod状态：
   kubectl get pods -A -o wide | grep -Ev "Running|Completed"

4. 如有Pod未恢复，可尝试强制删除：
   kubectl delete pod -n <namespace> <pod-name> --grace-period=0 --force

5. 检查系统服务状态：
   systemctl status kubelet containerd docker
==================================================
EOF
