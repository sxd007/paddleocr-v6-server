#!/bin/bash
set -e

# ── 检测部署模式 ─────────────────────────────────────────
if nvidia-smi 2>/dev/null | grep -q "NVIDIA" || \
   [ -f /usr/local/cuda/version.json ]; then
  DEPLOY_MODE="${DEPLOY_MODE:-gpu}"
else
  DEPLOY_MODE="${DEPLOY_MODE:-cpu}"
fi

echo "=== PaddleOCR Server starting ==="
echo "Model:      PP-StructureV3"
echo "Deploy:     $DEPLOY_MODE"
echo "Device:     ${PADDLE_OCR_DEVICE:-auto}"
echo "HPI:        ${ENABLE_HPI:-false}"
echo "TRT:        ${USE_TENSORRT:-false}"

# ── GPU 专属初始化 ─────────────────────────────────────
if [ "$DEPLOY_MODE" = "gpu" ]; then
  CUDNN_PKG=/usr/local/lib/python3.10/dist-packages/nvidia/cudnn/lib
  if [ -d "$CUDNN_PKG" ] && ! ldconfig -p | grep -q cudnn_adv; then
    echo "$CUDNN_PKG" > /etc/ld.so.conf.d/cudnn-python.conf
    ldconfig
  fi
  export LD_LIBRARY_PATH=$CUDNN_PKG:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

  # HPI 检查
  python3 -c "import ultra_infer; print('HPI plugin: ready')" 2>/dev/null || echo "HPI: not installed"
fi

# =============================================================
# 服务架构：
#
#   :8090    MCP Server — 官方 paddleocr_mcp（PP-StructureV3）
#   :8091    文件上传服务（file-upload 容器）
# =============================================================

# ── MCP Server（PP-StructureV3） ────────────────────────────
#    使用自定义 pipeline 配置，复用 PP-OCRv6 模型
paddleocr_mcp \
  --model PP-StructureV3 \
  --pipeline_config /app/src/pp_structurev3_custom.yml \
  --http \
  --host 0.0.0.0 \
  --port 8090 &
echo "✅ PP-StructureV3 MCP Server on :8090 (pp_structurev3 tool)"

echo ""
echo "=============================================="
echo "  Service           Port   Description"
echo "  ─────────────────────────────────────────"
echo "  MCP               :8090  PP-StructureV3 MCP Server (pp_structurev3)"
echo "  File Upload       :8091  独立文件上传服务（另一容器）"
echo "=============================================="
echo ""

# ── 等待任意子进程退出 ────────────────────────────────
wait || true
