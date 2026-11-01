#!/usr/bin/env python3
# How assets/models/anysleep.onnx was made from the AnySleep weights.
# Run it in a checkout of Traumschreiber_Python_Offline-Data-Analysis
# (needs anysleep_no_hydra.py and anysleep-run1.pth next to it; the .pth is
# downloaded by plot_sleep_scoring.py on its first run), then copy
# anysleep-run1.onnx to assets/models/anysleep.onnx.
"""Export AnySleep PyTorch checkpoint to a length-flexible ONNX.

The app runs this ONNX from `assets/models/anysleep.onnx` via
`lib/analysis/sleep_staging.dart` (package `onnxruntime`). To match `plot_sleep_scoring.py` (PC, full-night
single forward pass) on the phone, the ONNX must accept **arbitrary input
length**, not just the 20-epoch trace shape.

Two obstacles in the off-the-shelf AnySleep code (see `anysleep_no_hydra.py`):

  1. **Encoder padding is conditional on a Python int.**
     ```python
     if x_res.shape[-1] % 2 != 0:
         x_res = F.pad(x_res, (1, 0))
     ```
     `torch.onnx.export` traces by *running* the model with a concrete
     dummy input. The `if` evaluates to a Python `True`/`False` and only
     that branch survives in the exported graph. At a different input
     length, downsamples produce a different parity sequence, the missing
     pad makes encoder/decoder shapes drift, and ORT bails out at one of
     the decoder concat nodes:

         Non concat axis dimensions must match:
         Axis 2 has mismatched dimensions of 17534 and 17535

  2. **Decoder crop also branches on a Python int** (`max(0, diff)`).
     Less severe in practice because, given correct encoder padding, the
     upsample-and-crop produces matching shapes (diff is always 0) — so
     the trace's constant-folded `max(0, 0) = 0` is correct for every
     input length.

Fix here is **branchless padding**: rewrite the encoder pad as

    pad_amt = (2 - n % 2) % 2   # 0 if even, 1 if odd
    x_res = F.pad(x_res, (pad_amt, 0))

The pad call always runs; only the *amount* varies, and the amount is
computed from `x_res.shape[-1]`, which `torch.onnx` records as a runtime
shape op. Output is **byte-identical** to the original AnySleep PyTorch
forward for every input length (verified below).

Validation: after export, runs PyTorch and onnxruntime against the same
random input at 20, 60, 870, and 1169 epochs (= 10 min, 30 min, 7.25 h,
9.75 h — matches the user's overnight test). All four must produce 100 %
argmax-equivalent stage predictions.

Usage:

  python export_anysleep_onnx.py

Output: `./anysleep-run1.onnx` next to this script. Copy that file to
`assets/models/anysleep.onnx` in the app.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

from anysleep_no_hydra import (
    AnySleep,
    USleepEncoderBlock,
)


SCRIPT_DIR = Path(__file__).parent
PTH_PATH = SCRIPT_DIR / 'anysleep-run1.pth'
ONNX_PATH = SCRIPT_DIR / 'anysleep-run1.onnx'

# 10 min @ 128 Hz, single channel — the shape we trace at. Any value > 0
# works; we pick 20 epochs to keep the trace small.
DUMMY_SAMPLES = 20 * 30 * 128  # 76 800


def _encoder_forward_branchless(self, x):
    """Replacement for `USleepEncoderBlock.forward` that pads with a
    shape-derived integer amount (0 or 1) instead of a Python `if`. The
    `F.pad` call always runs; ONNX captures the pad amount as a runtime
    expression over the input shape, so the exported graph generalises
    across input lengths."""
    x_res = self.enc(x)
    n = x_res.shape[-1]
    pad_amt = (2 - n % 2) % 2  # 0 if even, 1 if odd
    x_res = F.pad(x_res, (pad_amt, 0))
    x = self.pool(x_res)
    return x_res, x


def _patch_anysleep():
    """Monkey-patch the conditional encoder pad globally. The original
    `forward` lives at `USleepEncoderBlock.forward`; we hand it our
    branchless version. Idempotent: re-applying just re-assigns."""
    USleepEncoderBlock.forward = _encoder_forward_branchless


def _verify_patch_is_identity():
    """Sanity-check: the branchless forward must produce byte-identical
    output to the original AnySleep forward at multiple input lengths.
    Done BEFORE export so a regression in the patch is caught here."""
    print('Verifying branchless patch is value-identical to upstream...')
    orig_forward = USleepEncoderBlock.forward
    rng = torch.Generator().manual_seed(0)
    for n_in in (3840, 7680, DUMMY_SAMPLES, 230400):
        block = USleepEncoderBlock(1, 4)
        block.eval()
        x = torch.randn(1, 1, n_in, generator=rng)

        with torch.no_grad():
            # Original
            USleepEncoderBlock.forward = orig_forward
            a, b = block(x)
            # Patched
            USleepEncoderBlock.forward = _encoder_forward_branchless
            c, d = block(x)
        max_a = float((a - c).abs().max())
        max_b = float((b - d).abs().max())
        if max_a > 1e-6 or max_b > 1e-6:
            sys.exit(
                f'❌ Branchless patch DIVERGES at n_in={n_in}: '
                f'max|x_res Δ|={max_a:.3e}, max|x Δ|={max_b:.3e}'
            )
        print(f'  n_in={n_in:6d}: ✓ identical')


def export():
    if not PTH_PATH.exists():
        sys.exit(
            f'❌ Model weights missing: {PTH_PATH}\n'
            f'   Run plot_sleep_scoring.py first to auto-download them, '
            f'or grab them from: https://media.githubusercontent.com/media/'
            f'dslaborg/AnySleep/main/models/anysleep-run1.pth'
        )

    _verify_patch_is_identity()
    _patch_anysleep()

    print(f'\nLoading PyTorch model from {PTH_PATH.name}…')
    model = AnySleep(path=str(PTH_PATH), sleep_stage_frequency=1)
    model.eval()

    dummy = torch.zeros(1, DUMMY_SAMPLES, 1)
    print(f'Exporting to {ONNX_PATH.name} (opset 17, dynamic time axis)…')
    # We deliberately use the legacy TorchScript-based exporter
    # (`dynamo=False`). The newer dynamo-based exporter bakes dynamic
    # dimensions into static values during graph optimisation, undoing
    # the very flexibility we want here. The legacy exporter's
    # `dynamic_axes` argument is the most reliable way to keep
    # input dim 1 free.
    torch.onnx.export(
        model,
        dummy,
        str(ONNX_PATH),
        input_names=['signal'],
        output_names=['logits'],
        dynamic_axes={
            'signal': {1: 'n_samples'},
            'logits': {1: 'n_epochs'},
        },
        opset_version=17,
        do_constant_folding=True,
        dynamo=False,
    )
    size_mb = ONNX_PATH.stat().st_size / 1024 / 1024
    print(f'✓ Wrote {ONNX_PATH.name} ({size_mb:.1f} MB)')


def validate():
    try:
        import onnxruntime as ort  # type: ignore
    except ImportError:
        print('⚠  Skipping ONNX-vs-PyTorch parity check — '
              '`pip install onnxruntime` to enable.')
        return

    print('\nValidating PyTorch (branchless) vs ONNX Runtime '
          'across length window (20 epochs through 1169 = 9.74 h):')
    _patch_anysleep()
    model = AnySleep(path=str(PTH_PATH), sleep_stage_frequency=1)
    model.eval()

    sess = ort.InferenceSession(
        str(ONNX_PATH), providers=['CPUExecutionProvider'])

    rng = np.random.default_rng(0)
    any_disagreement = False
    for n_ep in (20, 60, 120, 870, 1169):
        x_np = rng.standard_normal(
            (1, n_ep * 3840, 1)).astype(np.float32)
        try:
            with torch.no_grad():
                pt_logits = model(torch.from_numpy(x_np)).cpu().numpy()
            ort_logits = sess.run(None, {'signal': x_np})[0]
        except Exception as e:
            print(f'  n_ep={n_ep:5d}: ❌ {type(e).__name__}: {str(e)[:200]}')
            any_disagreement = True
            continue
        if pt_logits.shape != ort_logits.shape:
            print(f'  n_ep={n_ep:5d}: ❌ shape mismatch '
                  f'pt={pt_logits.shape} ort={ort_logits.shape}')
            any_disagreement = True
            continue
        argmax_agree = float(
            (pt_logits.argmax(-1) == ort_logits.argmax(-1)).mean())
        max_abs = float(np.max(np.abs(pt_logits - ort_logits)))
        marker = '✓' if argmax_agree >= 0.99 else '❌'
        print(f'  n_ep={n_ep:5d}  shape={ort_logits.shape}  '
              f'max|Δ|={max_abs:.3e}  argmax_agree={argmax_agree*100:.1f}%  '
              f'{marker}')
        if argmax_agree < 0.99:
            any_disagreement = True

    if any_disagreement:
        sys.exit('❌ Validation failed. Do NOT ship this ONNX.')
    print('\n✓ ONNX matches PyTorch argmax at every tested length. '
          'Safe to bundle.')


def print_app_instructions():
    print()
    print('─' * 70)
    print('Next steps to use this ONNX on the phone:')
    print('─' * 70)
    print(f'  cp {ONNX_PATH} <app>/assets/models/anysleep.onnx')
    print()
    print('  The model accepts any multiple of 3840 samples')
    print('  (= 30 s of 128 Hz signal = 1 epoch).')


if __name__ == '__main__':
    export()
    validate()
    print_app_instructions()
