# Python venv セットアップ (slim_yaml 用)

slim_yaml.py の実行には PyYAML が必要でございます。以下で venv を構築されたし:

```bash
python3 -m venv .venv
.venv/bin/pip install pyyaml
```

slim_yaml.sh は `.venv/bin/python3` を自動検出して使用いたします。
venv が存在しない場合は `python3` にフォールバックいたします。

## 環境変数による上書き

```bash
SHOGUN_PYTHON_BIN=/path/to/python3 bash scripts/slim_yaml.sh karo
SHOGUN_QUEUE_DIR=/path/to/queue   bash scripts/slim_yaml.sh karo
```
