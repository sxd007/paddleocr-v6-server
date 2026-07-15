"""
独立文件上传 HTTP 服务

功能:
  - POST /upload    → 上传文件，返回可访问 URL
  - GET /uploads/*  → 提供文件下载
  - 文件在上传后 FILE_RETENTION_MINUTES 分钟后自动删除

运行在独立容器（无需 GPU），与 paddleocr/mcp 解耦。
端口: 8091
"""

import os
import uuid
import asyncio
from pathlib import Path

from fastapi import FastAPI, UploadFile, HTTPException
from fastapi.responses import FileResponse
from starlette import status as http_status

# ── 环境变量配置 ────────────────────────────────────────────

UPLOAD_DIR = Path(os.getenv("UPLOAD_DIR", "/app/uploads"))
MAX_FILE_SIZE = int(os.getenv("MAX_FILE_SIZE", str(50 * 1024 * 1024)))  # 50 MB
FILE_RETENTION_MINUTES = int(os.getenv("FILE_RETENTION_MINUTES", "5"))
ALLOWED_EXTENSIONS: set[str] = {
    ".jpg", ".jpeg", ".png", ".gif", ".bmp",
    ".tiff", ".tif", ".webp",
    ".pdf",
}
PUBLIC_URL_BASE = os.getenv("PUBLIC_URL_BASE", "http://localhost:8091").rstrip("/")
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8091"))

# ── App ─────────────────────────────────────────────────────

app = FastAPI(title="PaddleOCR File Upload Service")


async def _auto_delete(file_path: Path, delay_minutes: int) -> None:
    """延迟指定分钟后删除文件。"""
    await asyncio.sleep(delay_minutes * 60)
    try:
        if file_path.exists():
            file_path.unlink()
            print(f"Auto-deleted: {file_path.name}")
    except Exception as e:
        print(f"Auto-delete failed for {file_path.name}: {e}")


@app.post("/upload")
async def upload_file(file: UploadFile):
    """上传文件，返回可访问 URL。

    文件会在 {FILE_RETENTION_MINUTES} 分钟后自动删除。
    客户端拿到 URL 后传给 MCP 的 ocr 工具使用。
    """
    ext = Path(file.filename or "").suffix.lower()
    if not ext:
        raise HTTPException(http_status.HTTP_400_BAD_REQUEST, "文件必须有扩展名")
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            http_status.HTTP_400_BAD_REQUEST,
            f"不允许的文件类型 '{ext}'。允许: {', '.join(sorted(ALLOWED_EXTENSIONS))}",
        )

    data = await file.read()
    if len(data) > MAX_FILE_SIZE:
        raise HTTPException(
            http_status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            f"文件过大。上限: {MAX_FILE_SIZE // (1024 * 1024)} MB",
        )

    unique_name = f"{uuid.uuid4().hex}{ext}"
    save_path = UPLOAD_DIR / unique_name
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

    with open(save_path, "wb") as f:
        f.write(data)

    # 定时自动删除
    asyncio.create_task(_auto_delete(save_path, FILE_RETENTION_MINUTES))

    file_url = f"{PUBLIC_URL_BASE}/uploads/{unique_name}"

    # MCP 容器通过共享卷也能在本地路径读到同一文件
    local_path = str(UPLOAD_DIR / unique_name)

    return {
        "url": file_url,
        "local_path": local_path,
        "filename": file.filename,
        "stored_as": unique_name,
        "size": len(data),
        "content_type": file.content_type,
        "auto_delete_in_minutes": FILE_RETENTION_MINUTES,
    }


@app.get("/uploads/{filename:path}")
async def serve_file(filename: str):
    """提供已上传文件的下载。"""
    if "/" in filename or "\\" in filename or ".." in filename:
        raise HTTPException(http_status.HTTP_400_BAD_REQUEST, "非法的文件名")

    file_path = UPLOAD_DIR / filename
    if not file_path.exists():
        raise HTTPException(http_status.HTTP_404_NOT_FOUND, "文件不存在或已被自动删除")

    return FileResponse(str(file_path))


@app.get("/health")
async def health():
    return {"status": "ok", "service": "file-upload"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT)
