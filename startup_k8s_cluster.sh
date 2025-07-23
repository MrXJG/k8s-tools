#!/bin/bash

# Kubernetes集群优雅开机后处理脚本（在master01上执行）
# 功能：检查并恢复集群状态，确保所有节点和Pod正常运行

# 定义节点列表
WORKER_NODES=("work01" "work02" "work03" "work04")
MASTER_NODES=("master01" "master02" "master03")

# 配置参数
NODE_CHECK_TIMEOUT=300          # 节点检查超时时间(秒)
NODE_CHECK_INTERVAL=10          # 节点状态检查间隔(秒)
MAX_SERVICE_RETRY=3             # 服务启动最大重试次数
APISERVER_WAIT_TIMEOUT=300      # API服务器等待超时(秒)
POD_RECOVERY_TIMEOUT=600        # Pod恢复等待超时(秒)

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 检查节点是否可访问
check_node_accessible() {
    if ssh -o ConnectTimeout=5 $1 "echo Connected" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 检查节点上的服务状态
check_node_services() {
    local node=$1
    local retry=0
    
    while [ $retry -lt $MAX_SERVICE_RETRY ]; do
        log "检查节点 $node 上的服务状态 (尝试 $((retry+1))/$MAX_SERVICE_RETRY)..."
        
        # 检查kubelet状态
        kubelet_status=$(ssh $node "sudo systemctl is-active kubelet 2>/dev/null")
        if [ "$kubelet_status" != "active" ]; then
            log "节点 $node 上的kubelet未运行，尝试启动..."
            ssh $node "sudo systemctl start kubelet"
            sleep 5
            retry=$((retry+1))
            continue
        fi
        
        # 检查容器运行时状态
        runtime_status=$(ssh $node "sudo systemctl is-active containerd 2>/dev/null || sudo systemctl is-active docker 2>/dev/null")
        if [ "$runtime_status" != "active" ]; then
            log "节点 $node 上的容器运行时未运行，尝试启动..."
            ssh $node "sudo systemctl start containerd || sudo systemctl start docker"
            sleep 5
            retry=$((retry+1))
            continue
        fi
        
        log "节点 $node 上的所有服务已启动"
        return 0
    done
    
    log "错误: 无法启动节点 $node 上的所有服务"
    return 1
}

# 等待节点加入集群
wait_node_ready() {
    local node=$1
    local start_time=$(date +%s)
    
    log "等待节点 $node 加入集群..."
    
    while [ $(($(date +%s) - start_time)) -lt $NODE_CHECK_TIMEOUT ]; do
        if sudo kubectl get node $node &>/dev/null; then
            node_status=$(sudo kubectl get node $node -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
            if [ "$node_status" == "True" ]; then
                log "节点 $node 已就绪"
                return 0
            fi
        fi
        sleep $NODE_CHECK_INTERVAL
    done
    
    log "错误: 节点 $node 加入集群超时"
    return 1
}

# 检查kube-apiserver可用性
wait_for_apiserver() {
    local start_time=$(date +%s)
    
    log "等待kube-apiserver可用..."
    
    while [ $(($(date +%s) - start_time)) -lt $APISERVER_WAIT_TIMEOUT ]; do
        if sudo kubectl get nodes &>/dev/null; then
            log "kube-apiserver已可用"
            return 0
        fi
        sleep 5
    done
    
    log "错误: 等待kube-apiserver超时"
    return 1
}

# 恢复节点调度
uncordon_nodes() {
    log "恢复worker节点调度能力..."
    
    for worker in "${WORKER_NODES[@]}"; do
        if sudo kubectl get node $worker &>/dev/null; then
            node_status=$(sudo kubectl get node $worker -o jsonpath='{.spec.unschedulable}')
            if [ "$node_status" == "true" ]; then
                log "正在恢复节点 $worker 的调度能力..."
                sudo kubectl uncordon $worker
            else
                log "节点 $worker 已可调度"
            fi
        else
            log "警告: 节点 $worker 未注册到集群"
        fi
    done
}

# 检查并等待Pod恢复
wait_pods_recovery() {
    local start_time=$(date +%s)
    local pending_pods=0
    
    log "等待所有Pod恢复..."
    
    while [ $(($(date +%s) - start_time)) -lt $POD_RECOVERY_TIMEOUT ]; do
        pending_pods=$(sudo kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o json | jq -r '.items | length')
        
        if [ "$pending_pods" -eq 0 ]; then
            log "所有Pod已恢复"
            return 0
        fi
        
        log "仍有 $pending_pods 个Pod未就绪，等待..."
        sleep 20
    done
    
    log "警告: 仍有 $pending_pods 个Pod未就绪"
    return 1
}

# 检查集群状态
check_cluster_status() {
    log "============ 集群状态检查 ============"
    
    # 检查节点状态
    log "[1/4] 节点状态:"
    sudo kubectl get nodes -o wide
    
    # 检查核心组件状态
    log "[2/4] 核心组件状态:"
    sudo kubectl get pods -n kube-system -o wide
    
    # 检查异常Pod状态
    log "[3/4] 异常Pod状态:"
    sudo kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide 2>/dev/null || true
    
    # 检查服务状态
    log "[4/4] 本地服务状态:"
    systemctl status kubelet containerd docker | grep -B 1 "Active:" || true
}

# 主执行流程
log "开始Kubernetes集群启动后处理流程"

# 1. 等待API服务器可用
if ! wait_for_apiserver; then
    log "错误: 无法连接到kube-apiserver，请手动检查master节点状态"
    exit 1
fi

# 2. 检查并确保所有节点服务正常运行
log "开始检查所有节点服务状态..."
for node in "${MASTER_NODES[@]}" "${WORKER_NODES[@]}"; do
    if check_node_accessible $node; then
        check_node_services $node
        wait_node_ready $node
    else
        log "警告: 节点 $node 不可访问，跳过检查"
    fi
done

# 3. 恢复worker节点调度
uncordon_nodes

# 4. 等待Pod恢复
wait_pods_recovery

# 5. 全面检查集群状态
check_cluster_status

log "Kubernetes集群启动后处理流程完成"

cat <<EOF

==================================================
[!] 集群状态检查清单 [!]

1. 所有节点状态应为Ready：
   kubectl get nodes -o wide

2. 所有核心组件应运行正常：
   kubectl get pods -n kube-system | grep -v Running

3. 异常Pod处理建议：
   - 查看日志：kubectl logs -n <namespace> <pod-name> --previous
   - 删除重建：kubectl delete pod -n <namespace> <pod-name>
   - 检查事件：kubectl describe pod -n <namespace> <pod-name>

4. 节点故障处理：
   - 检查服务状态：ssh <node> "systemctl status kubelet containerd"
   - 查看kubelet日志：ssh <node> "journalctl -u kubelet -n 100 --no-pager"

5. 网络问题检查：
   - 检查CNI插件：kubectl get pods -n kube-system | grep -E 'flannel|calico|cilium'
   - 检查网络连接：kubectl run net-test --image=alpine --rm -it -- ping <target-ip>
==================================================
EOF
