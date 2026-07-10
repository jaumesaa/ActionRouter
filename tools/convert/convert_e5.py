#!/usr/bin/env python3
"""Convert intfloat/multilingual-e5-small to a Core ML package for ActionRouter.

The exported model takes tokenized input (input_ids, attention_mask) and
returns a unit-normalized mean-pooled sentence embedding, so the Swift side
only needs to tokenize and run prediction.

Outputs (in --output, default ./build):
  MultilingualE5Small.mlpackage        FP16 weights (default)
  MultilingualE5Small-Int8.mlpackage   int8 linearly quantized (with --int8)
  tokenizer.json, tokenizer_config.json, special_tokens_map.json
  parity_report.txt                    cosine parity vs the PyTorch reference

Usage:
  python convert_e5.py [--int8] [--output DIR]

Requires: torch, transformers, coremltools (see requirements.txt).
"""

import argparse
import pathlib

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

MODEL_ID = "intfloat/multilingual-e5-small"
MAX_LENGTH = 128


PAD_TOKEN_ID = 1  # XLM-R <pad>


class PooledE5(torch.nn.Module):
    """E5 encoder + masked mean pooling + L2 normalization.

    The attention mask is derived inside the model (input_ids != <pad>), so
    the exported Core ML model has a single input. That matters: below
    iOS 18 / macOS 15, Core ML allows enumerated (Neural-Engine-friendly)
    shapes on only ONE input.
    """

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids):
        attention_mask = input_ids.ne(PAD_TOKEN_ID).to(torch.int32)
        hidden = self.model(
            input_ids=input_ids, attention_mask=attention_mask
        ).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1e-9)
        return torch.nn.functional.normalize(pooled, dim=-1)


def convert(output_dir: pathlib.Path, int8: bool) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModel.from_pretrained(MODEL_ID).eval()
    wrapped = PooledE5(model).eval()

    example = tokenizer(
        ["query: convertir a wav"], padding="max_length", truncation=True,
        max_length=MAX_LENGTH, return_tensors="pt",
    )
    example_ids = example["input_ids"].to(torch.int32)

    traced = torch.jit.trace(wrapped, (example_ids,))

    # Enumerated (fixed) sequence lengths instead of a RangeDim: the Neural
    # Engine rejects data-dependent shapes, so a flexible-shape model falls
    # back to CPU/GPU. The Swift provider pads inputs to the next bucket.
    shapes = ct.EnumeratedShapes(shapes=[(1, 32), (1, 64), (1, MAX_LENGTH)])
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=shapes, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.author = "Converted from intfloat/multilingual-e5-small (MIT)"
    mlmodel.license = "MIT"
    mlmodel.short_description = (
        "Multilingual sentence embeddings (384-dim) for ActionRouter. "
        "Mean-pooled, L2-normalized. Prefix inputs with 'query: ' or 'passage: '."
    )
    fp16_path = output_dir / "MultilingualE5Small.mlpackage"
    mlmodel.save(str(fp16_path))
    print(f"saved {fp16_path}")

    if int8:
        import coremltools.optimize.coreml as cto

        config = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric")
        )
        quantized = cto.linear_quantize_weights(mlmodel, config)
        int8_path = output_dir / "MultilingualE5Small-Int8.mlpackage"
        quantized.save(str(int8_path))
        print(f"saved {int8_path}")

    tokenizer.save_pretrained(str(output_dir / "tokenizer"))
    print(f"saved tokenizer files to {output_dir / 'tokenizer'}")

    parity_report(output_dir, wrapped, tokenizer)


def parity_report(output_dir: pathlib.Path, reference, tokenizer) -> None:
    """Compare Core ML predictions against the PyTorch reference."""
    texts = [
        "query: convertir a wav",
        "query: treu el fons de la foto",
        "passage: Remove image background. Removes the background from a picture.",
        "query: 将视频压缩得更小",
        "query: order a pizza",
    ]
    mlmodel = ct.models.MLModel(
        str(output_dir / "MultilingualE5Small.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    lines = []
    worst = 1.0
    buckets = [32, 64, MAX_LENGTH]
    for text in texts:
        batch = tokenizer([text], truncation=True, max_length=MAX_LENGTH,
                          return_tensors="pt")
        ids = batch["input_ids"].to(torch.int32)
        with torch.no_grad():
            expected = reference(ids)[0].numpy()
        # Pad to the next enumerated bucket, exactly as the Swift provider does.
        bucket = next(b for b in buckets if b >= ids.shape[1])
        pad = bucket - ids.shape[1]
        ids_np = np.pad(ids.numpy(), ((0, 0), (0, pad)),
                        constant_values=PAD_TOKEN_ID).astype(np.int32)
        got = mlmodel.predict({"input_ids": ids_np})["embedding"][0]
        cos = float(np.dot(expected, got)
                    / (np.linalg.norm(expected) * np.linalg.norm(got)))
        worst = min(worst, cos)
        lines.append(f"cos={cos:.6f}  {text!r}")
    report = "\n".join(lines) + f"\nworst={worst:.6f}\n"
    (output_dir / "parity_report.txt").write_text(report)
    print(report)
    if worst < 0.999:
        raise SystemExit("PARITY FAILURE: Core ML output diverges from PyTorch")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path(__file__).parent / "build")
    parser.add_argument("--int8", action="store_true",
                        help="also export an int8-quantized variant")
    args = parser.parse_args()
    convert(args.output, args.int8)
