#! python

import json
import numpy as np
import argparse


def main(timing: list) -> np.ndarray:

    slices = []
    for time in np.unique(timing):
        slices.append(np.where(time == timing)[0])

    return np.array(slices)


if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-s", "--sidecar", help="JSON sidecar file", type=str, required=True
    )
    parser.add_argument(
        "-o", "--output", help="Output MB slice order file", type=str, required=True
    )
    args = parser.parse_args()

    with open(args.sidecar, "r") as f:
        sidecar = json.load(f)

    timing = sidecar["SliceTiming"]
    mb_accel = sidecar["MultibandAccelerationFactor"]

    slice_order = []
    for time in np.unique(timing):
        slice_order.append(np.where(time == timing)[0])

    # sanity check - the numbr of indices of a certain slice time should be equal to the mulitband acceleration factor
    assert slice_order[0].size == mb_accel

    np.savetxt(args.output, slice_order, fmt="%d")
