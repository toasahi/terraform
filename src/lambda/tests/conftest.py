import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "layer" / "python"))
sys.path.insert(0, str(ROOT / "normalize"))
sys.path.insert(0, str(ROOT / "keep_dispatcher"))

os.environ.setdefault("AWS_REGION", "ap-northeast-1")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("JOURNAL_TABLE", "test-journal")
os.environ.setdefault("ALERTS_FIFO_URL", "https://sqs.example/alerts.fifo")
os.environ.setdefault("KEEP_DELIVERY_FIFO_URL", "https://sqs.example/keep-delivery.fifo")
os.environ.setdefault("KEEP_API_URL", "http://keep.internal:8080")
os.environ.setdefault("KEEP_APP_SECRET_ARN", "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:test")
