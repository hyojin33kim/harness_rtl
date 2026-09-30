# SpaceWire reviewed RTL candidate

This directory is the Gate 2 candidate derived from the supplied five RTL files.
It is intentionally separate from the original baseline.

Run locally:

```bash
sudo apt-get install iverilog
./run_regression.sh
```

The regression always emits and checks a non-empty VCD for every executed
test. Gate-2 P0 coverage currently includes:

- simultaneous TX-credit `+8/-1` atomic update;
- error-over-RX-commit priority;
- FCT FIFO-reserve boundary;
- held-valid/data and atomic ESC/FCT backpressure;
- continuous bit spacing across character boundaries.

The authoritative status and remaining closure items are in
`RTL_GATE2_REVIEW.md`.
