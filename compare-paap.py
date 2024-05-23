#! python

import numpy as np
import nibabel as nib
import argparse
import json
from collections.abc import Generator


def main(ap_basename: str, pa_basename: str) -> Generator[tuple, None, None]:

    ap = nib.load(ap_basename + ".nii.gz")
    pa = nib.load(pa_basename + ".nii.gz")

    ap_bvals = np.loadtxt(ap_basename + ".bval")
    pa_bvals = np.loadtxt(pa_basename + ".bval")

    ap_bvecs = np.loadtxt(ap_basename + ".bvec")
    pa_bvecs = np.loadtxt(pa_basename + ".bvec")

    with open(ap_basename + ".json", "r") as f:
        ap_sidecar = json.load(f)
    with open(pa_basename + ".json", "r") as f:
        pa_sidecar = json.load(f)

    in_arrays = {
        "affines": [ap.affine, pa.affine],
        "bvals": [ap_bvals, pa_bvals],
        "bvecs": [ap_bvecs, pa_bvecs],
        "ShimSetting": [ap_sidecar["ShimSetting"], pa_sidecar["ShimSetting"]],
        "SliceTiming": [ap_sidecar["SliceTiming"], pa_sidecar["SliceTiming"]],
        "EchoTime": [ap_sidecar["EchoTime"], pa_sidecar["EchoTime"]],
        "RepetitionTime": [ap_sidecar["RepetitionTime"], pa_sidecar["RepetitionTime"]],
        "FlipAngle": [ap_sidecar["FlipAngle"], pa_sidecar["FlipAngle"]],
        "TxRefAmp": [ap_sidecar["TxRefAmp"], pa_sidecar["TxRefAmp"]],
        "EchoTrainLength": [
            ap_sidecar["EchoTrainLength"],
            pa_sidecar["EchoTrainLength"],
        ],
        "EffectiveEchoSpacing": [
            ap_sidecar["EffectiveEchoSpacing"],
            pa_sidecar["EffectiveEchoSpacing"],
        ],
        "TotalReadoutTime": [
            ap_sidecar["TotalReadoutTime"],
            pa_sidecar["TotalReadoutTime"],
        ],
        "PixelBandwidth": [ap_sidecar["PixelBandwidth"], pa_sidecar["PixelBandwidth"]],
        "DwellTime": [ap_sidecar["DwellTime"], pa_sidecar["DwellTime"]],
    }

    for key, value in in_arrays.items():
        value = np.array(value)
        yield (
            key,
            [
                np.array_equal(value[0], value[1]),
                np.allclose(value[0], value[1]),
                np.abs(value[0] - value[1]).max(),
            ],
        )


if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument("-a", "--ap_basename", help="Basename of the AP scan", type=str)
    parser.add_argument("-p", "--pa_basename", help="Basename of the PA scan", type=str)
    args = parser.parse_args()

    comparisons = main(args.ap_basename, args.pa_basename)

    print(f"Comparing {args.ap_basename} with {args.pa_basename}\n")
    for name, comparison in comparisons:
        isequal, close, maxdev = comparison
        text = f">>> {name: >20}:   match {str(isequal): >5}; close {str(close): >5}; deviation {maxdev}"
        print(text)
