#!/usr/bin/env fslpython

import argparse
import numpy as np
from fsl.data import dtifit
import nibabel as nib


def main(
    l1: np.ndarray,
    l2: np.ndarray,
    l3: np.ndarray,
    v1: np.ndarray,
    v2: np.ndarray,
    v3: np.ndarray,
) -> np.ndarray:

    tensor = dtifit.eigendecompositionToComponents(
        L1=l1, L2=l2, L3=l3, V1=v1, V2=v2, V3=v3
    )
    return tensor


if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-l",
        "--eigenvalues",
        help="L1, L2 and L3 eigenvalue images",
        nargs=3,
        type=str,
        required=True,
    )
    parser.add_argument(
        "-v",
        "--eigenvectors",
        help="V1, V2 and V3 eigenvector images",
        nargs=3,
        type=str,
        required=True,
    )
    parser.add_argument(
        "-o", "--output", help="Output tensor file", type=str, required=True
    )

    args = parser.parse_args()
    L = [nib.load(file).get_fdata() for file in args.eigenvalues]
    V = [nib.load(file).get_fdata() for file in args.eigenvectors]

    tensor = main(*L, *V)

    tensor_img = nib.Nifti1Image(tensor, affine=nib.load(args.eigenvalues[0]).affine)
    nib.save(tensor_img, args.output)
