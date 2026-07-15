# PaddleOCR v6 Server

基于 PaddleOCR v6 + PP-StructureV3 的高性能 OCR 服务，提供 **MCP 协议**的 OCR 文字识别和表格识别能力。

## 📋 功能

| 功能 | 说明 |
|------|------|
| **OCR 文字识别** | MCP 工具 `ocr` — 支持图片/PDF文字提取，自动纠偏、旋转 |
| **表格识别** | MCP 工具 `ocr_table` — 识别图片/PDF中的表格，输出 HTML |
| **文件上传** | HTTP 文件上传服务，自动清理过期文件 |
| **多页 PDF** | 自动逐页渲染并识别 |
| **批处理** | 内置 BatchProcessor 提高吞吐量（FastAPI 端口:8000） |
| **PP-StructureV3** | 版面分析、印章识别、图表识别、表格识别 |

## 🚀 快速开始

### 前提条件

| 环境 | 要求 |
|------|------|
| **GPU（推荐）** | NVIDIA GPU + [Docker](https://docs.docker.com/engine/install/) + [nvidia-container-toolkit](#-安装-nvidia-container-toolkit) |
| **CPU** | Docker（任何架构） |
| **内存** | ≥ 8 GB（推荐 16 GB） |
| **磁盘** | ≥ 20 GB（模型权重约 5-10 GB） |

### 一键部署（推荐）

```bash
# 自动检测 GPU / CPU 并部署
./setup.sh
```

脚本会自动完成：
1. 检测 NVIDIA GPU 和 CUDA 版本
2. 无 GPU → CPU 模式自动切换
3. 检查 nvidia-container-toolkit（GPU 必需）
4. 生成 `.env` 配置文件
5. 拉取基础镜像 → 构建 → 启动 → 健康检查

### 分步部署

#### GPU 模式

```bash
# 1. 设置环境变量
export PUBLIC_URL_BASE=http://你的IP:8091

# 2. 启动
docker compose up -d

# 如果需要指定 CUDA 版本（默认 12.6）:
CUDA_VERSION=12.4 docker compose build \
  --build-arg BASE_IMAGE=nvidia/cuda:12.4.1-runtime-ubuntu22.04 \
  --build-arg PADDLE_WHEEL_CHANNEL=cu124
docker compose up -d
```

#### CPU 模式

```bash
PADDLE_DOCKERFILE=docker/Dockerfile.cpu docker compose up -d
```

### 停止服务

```bash
./setup.sh --down
# 或
docker compose down
```

## ⚙️ 部署选项

### 指定 CUDA 版本

```bash
# 30 系显卡（Ampere）
./setup.sh --cuda 11.8

# 40 系显卡（Ada Lovelace）
./setup.sh --cuda 12.6
```

### 强制模式

```bash
# 强制 GPU 模式（如自动检测失败时）
./setup.sh --gpu

# 强制 CPU 模式
./setup.sh --cpu
```

### 重新构建

```bash
# 强制重新构建镜像（更新依赖后使用）
./setup.sh --rebuild

# 或手动
docker compose build --no-cache
```

## 🔧 安装 nvidia-container-toolkit

GPU 模式需要 nvidia-container-toolkit 让 Docker 容器访问 GPU：

### Ubuntu / Debian

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update -y
sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

### 验证安装

```bash
# 检查 nvidia 运行时是否注册
docker info | grep Runtimes
# 输出应包含: nvidia

# 测试 GPU 容器
docker run --rm --runtime=nvidia nvidia/cuda:12.6.3-runtime-ubuntu22.04 nvidia-smi
```

## 📡 架构图

```
┌─────────────────────┐       ┌──────────────────────┐
│   Claude Code / IDE │       │   外部 HTTP 客户端    │
│   (MCP 客户端)       │       │                      │
└─────────┬───────────┘       └──────────┬───────────┘
          │ MCP 协议                     │ HTTP
          ▼                              ▼
┌─────────────────────┐       ┌──────────────────────┐
│  PaddleOCR MCP      │       │  文件上传服务         │
│  :8090               │       │  :8091                │
│                     │       │                      │
│  • ocr 工具         │       │  POST /upload        │
│  • ocr_table 工具   │       │  GET /uploads/*      │
│  • 共享 /uploads    │◄──────┤  • 共享 /uploads     │
└─────────┬───────────┘       └──────────────────────┘
          │
          ▼
┌─────────────────────┐
│  PaddleOCR v6       │
│  PP-StructureV3     │
│  + HPI / TensorRT   │
└─────────────────────┘
```

### 上传工作流

```
1. 客户端  ──POST /upload──► 文件上传服务（:8091）
                               │
2. 返回 ──{"url","local_path"}─► 客户端
                               │
3. 客户端 ──ocr(local_path)──► MCP Server（:8090）
                               │
4. 返回 ──识别结果文本────────► 客户端
```

## 📖 API 使用

### 上传文件

```bash
curl -X POST http://localhost:8091/upload \
  -F "file=@document.pdf"

# 成功返回:
{
  "url": "http://localhost:8091/uploads/abc123.pdf",
  "local_path": "/app/uploads/abc123.pdf",
  "filename": "document.pdf",
  "size": 123456,
  "content_type": "application/pdf",
  "auto_delete_in_minutes": 5
}
```

### MCP 工具：ocr

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `input_data` | string | ✅ | local_path, HTTP URL, or Base64 |
| `output_mode` | string | ❌ | `simple`（纯文本, 默认）或 `detailed`（JSON） |

#### simple 模式输出

```
识别后的文字内容

(Confidence: 95.2% | 42 text lines)
```

#### detailed 模式输出

```json
{
  "text": "识别后的全部文字内容",
  "confidence": 0.952,
  "text_lines": [
    {"text": "第一行", "confidence": 0.98, "bbox": [...]},
    {"text": "第二行", "confidence": 0.95, "bbox": [...]}
  ],
  "total_lines": 42
}
```

### MCP 工具：ocr_table

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `input_data` | string | ✅ | local_path, HTTP URL, or Base64 |
| `output_mode` | string | ❌ | `simple`（HTML, 默认）或 `detailed`（JSON） |

## 🐳 Docker 参考

### 镜像选择

| Dockerfile | 场景 | 基础镜像 |
|-----------|------|---------|
| `docker/Dockerfile.gpu` | NVIDIA GPU | `nvidia/cuda:X.X-runtime-ubuntu22.04` |
| `docker/Dockerfile.cpu` | CPU 或无 GPU | `python:3.10-slim-bookworm` |
| `docker/Dockerfile.upload` | 文件上传服务 | `python:3.11-slim` |

### Build Args（GPU）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `BASE_IMAGE` | `nvidia/cuda:12.6.3-runtime-ubuntu22.04` | CUDA 基础镜像 |
| `PADDLE_WHEEL_CHANNEL` | `cu126` | PaddlePaddle GPU wheel 频道 |

### CUDA 版本兼容性

| GPU 架构 | 显卡示例 | CUDA 版本 | Wheel 频道 |
|---------|---------|-----------|-----------|
| Ampere | RTX 3060 / 3080 / A100 | 11.8 | `cu118` |
| Ampere+ | RTX 3090 / A100 | 12.1 | `cu121` |
| Ada Lovelace | RTX 4060 / 4070 / 4080 | 12.4 | `cu124` |
| Ada Lovelace | **RTX 4090** / L40S | **12.6** | **cu126** ⬅ 默认 |

### 目录结构

```
├── docker/
│   ├── Dockerfile.gpu           # GPU Dockerfile
│   ├── Dockerfile.cpu           # CPU Dockerfile
│   └── Dockerfile.upload        # 文件上传服务
├── src/
│   ├── file_upload_server.py    # 文件上传 HTTP 服务
│   └── pp_structurev3_custom.yml # PP-StructureV3 pipeline 配置
├── docker-compose.yml           # Docker Compose 配置
├── .env.example                 # 环境变量模板（cp 后编辑）
├── setup.sh                     # ★ 一键部署脚本
├── start.sh                     # 容器启动入口
└── README.md                    # 本文档
```

## ❓ 常见问题

### Q: 容器启动后没有 GPU 加速？

确认 nvidia-container-toolkit 已安装并重启了 Docker：
```bash
sudo systemctl restart docker
./setup.sh --rebuild
```

### Q: 文件上传失败或返回 拒绝连接？

确认 `PUBLIC_URL_BASE` 设置为客户端可访问的地址：
```bash
# 在 .env 中设置
PUBLIC_URL_BASE=http://10.0.0.100:8091
```

### Q: 内存不足？

PaddleOCR 模型加载需要约 4 GB 内存。确保 `docker-compose.yml` 中的 `shm_size: 2g` 配置正确。

### Q: ARM64 / Apple Silicon 可以运行吗？

可以，但只能使用 CPU 模式。Docker Desktop 无法将 GPU 直通给 Linux 容器：
```bash
./setup.sh --cpu
```

### Q: 首次启动很慢？

首次启动需要下载模型权重（~5-10 GB），后续会自动缓存到 `./models/` 目录。

## 📄 许可

本项目基于 PaddleOCR（Apache 2.0）构建，请遵守其许可条款。
