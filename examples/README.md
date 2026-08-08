# examples

[`sample-batch.md`](sample-batch.md) 是一份**合成**的最小批次示例，用来演示唯一支持的 Markdown 输入格式：

```markdown
## <spelling>
<interpretation body>
```

它不是任何人的真实学习数据，词条和释义都是通用词典义项。

用它先跑一次预览（不会写入任何内容）：

```bash
python3 scripts/interpretation_batch_importer.py --mode dry-run --input examples/sample-batch.md --account-label "secondary-test" --allow-network
```

> `--mode create` 和 `--mode update` 会真实修改**你自己账号**中的自建释义。请先用副账号 / 测试账号，并在确认前逐条核对预览内容。

格式细节和各模式行为见仓库根目录的 [README](../README.md)。
