# Red Pitaya Butterfly Network Handover

This file used to describe the first ASG-fed neighboring-pair butterfly
milestone. That material is now obsolete: the FPGA design has moved to the
BNET register block, DDR readers, a full staged butterfly engine, and an
experimental fixed-weight frame-pipeline draft.

Use the merged current FPGA handover instead:

```text
HANDOVER_bnet_ddr_reader_compile_check.md
```

Historical note:

- The original milestone intercepted ASG A as samples and ASG B as packed
  weights.
- It computed one neighboring-pair butterfly stage and drove DAC A/B.
- That path was replaced by the current staged DDR-backed BNET architecture.
