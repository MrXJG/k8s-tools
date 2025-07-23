# Kubernetes 集群优雅关机与启动工具

## 项目简介

这两个脚本提供了 Kubernetes 集群的优雅关机(`shutdown_k8s_cluster.sh`)和启动后恢复(`startup_k8s_cluster.sh`)的自动化解决方案，特别适合需要定期维护或断电保护的 Kubernetes 环境。

## 功能特性

### 关机脚本 (`shutdown_k8s_cluster.sh`)
- 按正确顺序关闭集群节点（先 worker 后 master）
- 自动驱逐 Pod 并处理 PDB (Pod Disruption Budget) 限制
- 支持自定义超时和重试参数
- 提供详细的关机后操作指南

### 启动脚本 (`startup_k8s_cluster.sh`)
- 自动检查并恢复所有节点服务
- 等待 API 服务器可用
- 恢复 worker 节点调度能力
- 监控 Pod 恢复状态
- 提供全面的集群状态检查报告

## 使用说明

### 前提条件
- 需要在 Kubernetes master 节点上执行
- 配置好 SSH 免密登录到所有集群节点
- 确保执行用户有 sudo 权限
- 适用于使用 systemd 管理的 kubelet 和容器运行时

### 安装方法
```bash
git clone [https://github.com/MrXJG/k8s-graceful-shutdown.git](https://github.com/MrXJG/k8s-tools.git)
cd k8s-graceful-shutdown
chmod +x shutdown_k8s_cluster.sh startup_k8s_cluster.sh
```

### 使用方法

**优雅关机:**
```bash
./shutdown_k8s_cluster.sh
```

**集群启动后恢复:**
```bash
./startup_k8s_cluster.sh
```

### 配置调整
编辑脚本开头的变量部分以匹配您的集群配置：
```bash
# 节点列表
WORKER_NODES=("work01" "work02" "work03")
MASTER_NODES=("master01" "master02" "master03")

# 超时和重试参数
MAX_EVICT_RETRY=1               # 最大驱逐重试次数
FORCE_SHUTDOWN_TIMEOUT=3        # 强制关机前的等待时间(秒)
DRAIN_TIMEOUT=3                 # drain操作的超时时间
```

## 注意事项

1. 使用前请确保已备份重要数据
2. 生产环境使用前建议在测试环境验证
3. 强制驱逐 Pod 可能会影响有状态应用
4. 根据实际集群规模调整超时参数
5. 脚本假设使用 containerd/docker 作为容器运行时

## 贡献指南

欢迎提交 Issue 或 Pull Request 来改进项目。请确保：
- 代码风格与现有脚本一致
- 提交详细的变更说明
- 测试您的修改

## 许可证

[MIT License](LICENSE)

## 免责声明

此脚本按"原样"提供，作者不对使用此脚本造成的任何直接或间接损失负责。在生产环境使用前请充分测试。
