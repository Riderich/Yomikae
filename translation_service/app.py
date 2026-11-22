"""Thin JHenTai adapter for a manga-image-translator API server."""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Annotated

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import Response

app = FastAPI(title="JHenTai Translation Adapter", version="0.1.0")
logger = logging.getLogger("uvicorn.error")

TIMING_HEADER = "X-JHenTai-Timing"

# manga-image-translator stream frames: 1 byte status + 4 byte big-endian size + payload.
STREAM_RESULT = 0
STREAM_PROGRESS = 1
STREAM_ERROR = 2
STREAM_QUEUE_POSITION = 3
STREAM_WAITING_INSTANCE = 4


class _StreamUnsupported(Exception):
    """The engine has no streaming endpoint (older manga-image-translator)."""


ENGINE_URL = os.getenv("JHENTAI_MT_URL", "http://127.0.0.1:8000").rstrip("/")
API_TOKEN = os.getenv("JHENTAI_TRANSLATION_TOKEN", "")
TRANSLATOR = os.getenv("JHENTAI_MT_TRANSLATOR", "deepseek")
REQUEST_TIMEOUT_SECONDS = float(os.getenv("JHENTAI_MT_TIMEOUT", "300"))
ENGINE_TIMEOUT = httpx.Timeout(REQUEST_TIMEOUT_SECONDS, connect=10)

# Creating an httpx client loads the system certificate store, which takes about
# two seconds on Windows. Reuse one client for the engine instead of paying that
# on every page.
_engine_client: httpx.AsyncClient | None = None


def _get_engine_client() -> httpx.AsyncClient:
    global _engine_client
    if _engine_client is None or _engine_client.is_closed:
        _engine_client = httpx.AsyncClient(timeout=ENGINE_TIMEOUT)
    return _engine_client


@app.on_event("startup")
async def _create_engine_client() -> None:
    _get_engine_client()


@app.on_event("shutdown")
async def _close_engine_client() -> None:
    if _engine_client is not None:
        await _engine_client.aclose()

LANGUAGE_MAP = {
    "zh": "CHS",
    "zh-cn": "CHS",
    "zh-hans": "CHS",
    "zh-tw": "CHT",
    "zh-hant": "CHT",
    "en": "ENG",
    "en-us": "ENG",
    "ja": "JPN",
    "ja-jp": "JPN",
    "ko": "KOR",
    "ko-kr": "KOR",
}


def _check_token(authorization: str | None) -> None:
    if not API_TOKEN:
        return
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid translation service token")


def _engine_config(
    target_language: str,
    translation_provider: str,
    api_base_url: str,
    api_key: str,
    api_model: str,
    disable_thinking: bool,
) -> dict:
    try:
        config = json.loads(os.getenv("JHENTAI_MT_CONFIG_JSON", "{}"))
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=500, detail=f"Invalid JHENTAI_MT_CONFIG_JSON: {exc}") from exc

    translator = config.setdefault("translator", {})
    provider = translation_provider or TRANSLATOR
    translator["translator"] = "deepseek" if provider == "openai_compatible" else provider
    translator["target_lang"] = LANGUAGE_MAP.get(target_language.lower(), target_language.upper())
    if provider == "openai_compatible":
        translator["api_base_url"] = api_base_url.rstrip("/")
        translator["api_key"] = api_key
        translator["api_model"] = api_model or "deepseek-v4-flash"
        translator["disable_thinking"] = disable_thinking
    return config


@app.get("/health")
async def health() -> dict:
    try:
        response = await _get_engine_client().get(f"{ENGINE_URL}/openapi.json", timeout=5)
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"Translation engine unavailable: {exc}") from exc
    return {"status": "ok", "engine": ENGINE_URL}


@app.post("/v1/test")
async def test_configuration(
    translation_provider: Annotated[str, Form()] = "openai_compatible",
    api_base_url: Annotated[str, Form()] = "https://api.deepseek.com",
    api_key: Annotated[str, Form()] = "",
    api_model: Annotated[str, Form()] = "deepseek-v4-flash",
    disable_thinking: Annotated[bool, Form()] = True,
) -> dict:
    await health()
    if translation_provider != "openai_compatible":
        return {"status": "ok", "provider": translation_provider}
    payload = {
        "model": api_model,
        "messages": [{"role": "user", "content": "Reply only with OK"}],
        "max_tokens": 4,
    }
    if disable_thinking:
        payload["thinking"] = {"type": "disabled"}
    headers = {"Authorization": f"Bearer {api_key.strip()}"} if api_key.strip() else {}
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post(
                f"{api_base_url.rstrip('/')}/chat/completions",
                json=payload,
                headers=headers,
            )
            response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Translation API rejected the configuration (HTTP {exc.response.status_code})",
        ) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"Translation API unavailable: {exc}") from exc
    return {"status": "ok", "provider": translation_provider, "model": api_model}


@app.post("/v1/translate")
async def translate(
    image: Annotated[UploadFile, File()],
    gallery_id: Annotated[str, Form()],
    page_index: Annotated[int, Form()],
    source_language: Annotated[str, Form()] = "auto",
    target_language: Annotated[str, Form()] = "zh-CN",
    translation_provider: Annotated[str, Form()] = "openai_compatible",
    api_base_url: Annotated[str, Form()] = "https://api.deepseek.com",
    api_key: Annotated[str, Form()] = "",
    api_model: Annotated[str, Form()] = "deepseek-v4-flash",
    disable_thinking: Annotated[bool, Form()] = True,
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    del source_language
    started_at = time.perf_counter()
    _check_token(authorization)
    image_bytes = await image.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image")

    files = {"image": (image.filename or "page.jpg", image_bytes, image.content_type or "application/octet-stream")}
    data = {
        "config": json.dumps(
            _engine_config(
                target_language,
                translation_provider,
                api_base_url,
                api_key,
                api_model,
                disable_thinking,
            ),
            ensure_ascii=False,
        )
    }
    client = _get_engine_client()
    try:
        try:
            content, media_type, timing = await _translate_streaming(client, files, data)
        except _StreamUnsupported:
            content, media_type, timing = await _translate_blocking(client, files, data)
    except httpx.HTTPStatusError as exc:
        detail = exc.response.text[:1000]
        raise HTTPException(status_code=502, detail=f"Translation engine error: {detail}") from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"Translation engine unavailable: {exc}") from exc

    timing["adapter_total"] = round(time.perf_counter() - started_at, 3)
    logger.info(
        "Translated %s page %s (%d KB -> %d KB): %s",
        gallery_id,
        page_index,
        len(image_bytes) // 1024,
        len(content) // 1024,
        " ".join(f"{name}={seconds:.2f}s" for name, seconds in timing.items()),
    )
    return Response(
        content=content,
        media_type=media_type,
        headers={TIMING_HEADER: json.dumps(timing, separators=(",", ":"))},
    )


async def _translate_blocking(client: httpx.AsyncClient, files: dict, data: dict) -> tuple[bytes, str, dict]:
    """Single request without stage progress; only the total engine time is known."""
    started_at = time.perf_counter()
    result = await client.post(f"{ENGINE_URL}/translate/with-form/image", files=files, data=data)
    result.raise_for_status()
    timing = {"engine": round(time.perf_counter() - started_at, 3)}
    return result.content, result.headers.get("content-type", "image/png"), timing


async def _translate_streaming(client: httpx.AsyncClient, files: dict, data: dict) -> tuple[bytes, str, dict]:
    """Uses the engine's streaming endpoint so each pipeline stage can be timed.

    The engine reports the name of a stage when it starts, so a stage lasts until
    the next report. Time before the first report is upload, queueing and model
    loading on the engine side; time after ``finished`` is PNG encoding and transfer.
    """
    started_at = time.perf_counter()
    stages: list[tuple[str, float]] = []
    result: bytes | None = None
    result_at = started_at

    async with client.stream("POST", f"{ENGINE_URL}/translate/with-form/image/stream", files=files, data=data) as response:
        if response.status_code in (404, 405):
            raise _StreamUnsupported()
        if response.status_code >= 400:
            await response.aread()
            response.raise_for_status()

        buffer = bytearray()
        async for chunk in response.aiter_bytes():
            buffer.extend(chunk)
            while len(buffer) >= 5:
                status = buffer[0]
                size = int.from_bytes(buffer[1:5], "big")
                if len(buffer) < 5 + size:
                    break
                payload = bytes(buffer[5 : 5 + size])
                del buffer[: 5 + size]
                now = time.perf_counter()

                if status == STREAM_RESULT:
                    result = payload
                    result_at = now
                elif status == STREAM_PROGRESS:
                    stages.append((payload.decode("utf-8", "replace"), now))
                elif status == STREAM_ERROR:
                    detail = payload.decode("utf-8", "replace")[:1000]
                    raise HTTPException(status_code=502, detail=f"Translation engine error: {detail}")
                # STREAM_QUEUE_POSITION / STREAM_WAITING_INSTANCE only mean "still waiting".
            if result is not None:
                break

    if result is None:
        raise HTTPException(status_code=502, detail="Translation engine stream ended without a result")

    timing: dict[str, float] = {"engine_wait": (stages[0][1] if stages else result_at) - started_at}
    for i, (name, stage_started_at) in enumerate(stages):
        stage_ended_at = stages[i + 1][1] if i + 1 < len(stages) else result_at
        timing[name] = timing.get(name, 0.0) + (stage_ended_at - stage_started_at)
    timing["engine"] = result_at - started_at
    timing = {name: round(seconds, 3) for name, seconds in timing.items()}
    return result, "image/png", timing
