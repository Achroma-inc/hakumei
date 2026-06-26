"""hakumei コンテナの日次自動更新 Lambda。

EventBridge Scheduler から日次で呼ばれ、ECR Public 上の hakumei:latest が指す
現在の digest を取得し、ECS Express Gateway Service の primaryContainer.image を
`...@sha256:<digest>` 形式に差し替えて再デプロイする。

ECS Express は image 文字列が同一だと再 pull しないため、:latest を渡しても新しい
イメージは降りてこない。そこで毎回 digest を解決して image URI を変える。すでに
同じ digest が走っていれば何もせずに終了 (冪等)。

digest 解決は Docker Registry V2 protocol (HTTPS HEAD /v2/<repo>/manifests/<tag>) で
行い、ECR Public は anonymous token で叩けるため AWS IAM 権限は不要。

環境変数:
  SERVICE_ARN          : ECS Express Gateway Service の ARN (必須)
  ECR_REGISTRY_ALIAS   : ECR Public の registry alias (例: y2a9a6u8)
  ECR_REPOSITORY_NAME  : リポジトリ名 (例: hakumei)
  IMAGE_TAG            : 追跡するタグ (例: latest)
  AWS_REGION_ECS       : ECS Express が動くリージョン
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ECR_PUBLIC_HOST = "public.ecr.aws"
MANIFEST_ACCEPT = ",".join(
    [
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.index.v1+json",
    ]
)


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"required env var missing: {name}")
    return value


def _fetch_public_ecr_token() -> str:
    """ECR Public は anonymous でも bearer token を発行してくれる (public registry のため)。"""
    url = f"https://{ECR_PUBLIC_HOST}/token/?scope=aws&service={ECR_PUBLIC_HOST}"
    with urllib.request.urlopen(url, timeout=10) as response:
        payload = json.loads(response.read().decode("utf-8"))
    token = payload.get("token")
    if not token:
        raise RuntimeError("ECR Public token endpoint returned no token")
    return token


def _resolve_latest_digest(registry_alias: str, repository: str, tag: str) -> str:
    """Docker Registry V2 protocol (HEAD /v2/<repo>/manifests/<tag>) で digest を引く。

    レスポンスヘッダー `Docker-Content-Digest` が `sha256:<hex>` 形式で返る。
    """
    token = _fetch_public_ecr_token()
    url = f"https://{ECR_PUBLIC_HOST}/v2/{registry_alias}/{repository}/manifests/{tag}"
    request = urllib.request.Request(url, method="HEAD")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", MANIFEST_ACCEPT)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            digest = response.headers.get("Docker-Content-Digest")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(
            f"HEAD {url} failed: HTTP {exc.code} {exc.reason}"
        ) from exc
    if not digest:
        raise RuntimeError(f"Docker-Content-Digest header missing for {url}")
    if not digest.startswith("sha256:"):
        raise RuntimeError(f"unexpected digest format: {digest}")
    return digest


def _build_image_uri(registry_alias: str, repository: str, digest: str) -> str:
    return f"{ECR_PUBLIC_HOST}/{registry_alias}/{repository}@{digest}"


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    service_arn = _required_env("SERVICE_ARN")
    registry_alias = _required_env("ECR_REGISTRY_ALIAS")
    repository = _required_env("ECR_REPOSITORY_NAME")
    tag = _required_env("IMAGE_TAG")
    ecs_region = _required_env("AWS_REGION_ECS")

    digest = _resolve_latest_digest(registry_alias, repository, tag)
    new_image = _build_image_uri(registry_alias, repository, digest)
    logger.info("resolved %s/%s:%s -> %s", registry_alias, repository, tag, digest)

    ecs = boto3.client("ecs", region_name=ecs_region)
    described = ecs.describe_express_gateway_service(serviceArn=service_arn)
    primary = (
        described.get("service", {})
        .get("activeConfigurations", [{}])[0]
        .get("primaryContainer")
    )
    if not primary:
        raise RuntimeError(
            "primaryContainer not found in describe_express_gateway_service response"
        )

    current_image = primary.get("image")
    if current_image == new_image:
        logger.info("image already up to date (%s), nothing to do", current_image)
        return {"status": "noop", "image": current_image}

    primary["image"] = new_image
    ecs.update_express_gateway_service(
        serviceArn=service_arn,
        primaryContainer=primary,
    )
    logger.info("updated service %s: %s -> %s", service_arn, current_image, new_image)
    return {"status": "updated", "from": current_image, "to": new_image}
